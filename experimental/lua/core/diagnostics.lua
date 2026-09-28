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

return M
