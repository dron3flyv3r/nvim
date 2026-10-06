local M = {}

local severity = vim.diagnostic.severity

local insert_bufnr, insert_line = -1, -1

local current_line = true
local errors_only = false

---@type table<string, true>
local suspensions = {}

---@return boolean
function M.is_errors_only() return errors_only or next(suspensions) ~= nil end

local function apply()
  local filter = M.is_errors_only() and { min = severity.ERROR } or nil
  vim.diagnostic.config {
    severity_sort = true,
    underline = { severity = filter },
    update_in_insert = true,
    signs = {
      severity = filter,
      text = {
        [severity.ERROR] = "",
        [severity.WARN] = "",
        [severity.INFO] = "",
        [severity.HINT] = "",
      },
    },
    -- rustc and roslyn messages run to several lines, which end-of-line virtual
    -- text truncates; scoping the expansion to the cursor line is what keeps
    -- them whole without pushing the rest of the file off the screen.
    virtual_text = false,
    virtual_lines = { current_line = current_line, severity = filter },
    float = { source = "if_many" },
  }
end

function M.setup() apply() end

--- Widens the inline expansion from the cursor's line to every line, and back.
function M.toggle_all()
  current_line = not current_line
  apply()
  vim.notify(
    current_line and "Inline diagnostics: cursor line" or "Inline diagnostics: every line",
    vim.log.levels.INFO,
    { title = "Diagnostics" }
  )
end

--- An explicit toggle clears every suspension, so it always changes what is on screen.
function M.toggle_errors_only()
  errors_only = not M.is_errors_only()
  suspensions = {}
  apply()
  vim.notify(
    errors_only and "Diagnostics: errors only" or "Diagnostics: every severity",
    vim.log.levels.INFO,
    { title = "Diagnostics" }
  )
end

---@param reason string
function M.suspend(reason)
  suspensions[reason] = true
  apply()
end

---@param reason string
function M.resume(reason)
  suspensions[reason] = nil
  apply()
end

--- `virtual_lines.current_line` renders from `CursorHold`, which never fires in
--- insert mode, so the block stays under the line it was last published for
--- until the next publish moves it.
function M.on_insert_move(bufnr)
  local virtual_lines = vim.diagnostic.config().virtual_lines
  if type(virtual_lines) ~= "table" or virtual_lines.current_line ~= true then return end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  if bufnr == insert_bufnr and line == insert_line then return end
  insert_bufnr, insert_line = bufnr, line
  vim.diagnostic.show(nil, bufnr)
end

local PULL = "textDocument/diagnostic"
local REPULL_DELAY = 500

---@type table<integer, table<integer, true>>
local stale = {}
---@type table<integer, uv.uv_timer_t>
local repull_timers = {}
local warned = false

-- Without a previousResultId the server answers in full, and re-setting an
-- identical list redraws every inline block in the window, which flickers.
---@param client_id integer
---@param bufnr integer
---@param identifier? string
---@param items lsp.Diagnostic[]
---@return boolean
local function shown(client_id, bufnr, identifier, items)
  local namespace = vim.lsp.diagnostic.get_namespace(client_id, true, identifier)
  local current = vim.diagnostic.get(bufnr, { namespace = namespace })
  if #current ~= #items then return false end
  for i, diagnostic in ipairs(current) do
    if not vim.deep_equal(diagnostic.user_data and diagnostic.user_data.lsp, items[i]) then return false end
  end
  return true
end

---@param client vim.lsp.Client
---@param bufnr integer
---@param inter_file_only? boolean
function M.pull(client, bufnr, inter_file_only)
  if stale[client.id] then stale[client.id][bufnr] = nil end
  if not client.attached_buffers[bufnr] then return end
  if not client._provider_foreach then
    if not warned then
      warned = true
      vim.notify(
        "vim.lsp.Client:_provider_foreach is gone, so diagnostics in other files go stale after an edit",
        vim.log.levels.WARN,
        { title = "Diagnostics" }
      )
    end
    return
  end
  client:_provider_foreach(PULL, function(cap)
    if inter_file_only and not cap.interFileDependencies then return end
    local params = { identifier = cap.identifier, textDocument = vim.lsp.util.make_text_document_params(bufnr) }
    client:request(PULL, params, function(err, result, ctx)
      if not err and result and result.kind == "full" and shown(client.id, bufnr, cap.identifier, result.items) then
        return
      end
      vim.lsp.handlers[PULL](err, result, ctx)
    end, bufnr)
  end)
end

---@param client_id integer
local function repull_visible(client_id)
  local client = vim.lsp.get_client_by_id(client_id)
  if not client then
    stale[client_id] = nil
    return
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local bufnr = vim.api.nvim_win_get_buf(win)
    if stale[client_id] and stale[client_id][bufnr] then M.pull(client, bufnr, true) end
  end
end

-- Neovim re-pulls only the buffer that changed and ignores `interFileDependencies`,
-- so a caller in another file kept an error the edit had just fixed.
---@param client_id integer
---@param changed integer
function M.on_lsp_change(client_id, changed)
  local client = vim.lsp.get_client_by_id(client_id)
  if not client or not client:supports_method(PULL) then return end
  local marks = stale[client_id] or {}
  stale[client_id] = marks
  for bufnr in pairs(client.attached_buffers) do
    marks[bufnr] = bufnr ~= changed or nil
  end
  local timer = repull_timers[client_id] or assert(vim.uv.new_timer())
  repull_timers[client_id] = timer
  timer:start(REPULL_DELAY, 0, vim.schedule_wrap(function() repull_visible(client_id) end))
end

---@param bufnr integer
function M.on_enter(bufnr)
  for client_id, marks in pairs(stale) do
    local client = marks[bufnr] and vim.lsp.get_client_by_id(client_id)
    if client then M.pull(client, bufnr, true) end
  end
end

return M
