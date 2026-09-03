local M = {}

--- The lowest severity that is allowed to be seen, or nil for "all of them".
--- `ERROR` is 1 and `HINT` is 4, so this is a *maximum* number and reads
--- backwards; `severity_filter` below does the translating.
---@type integer|nil
M.min_severity = nil

--- The `severity` value to hand `vim.diagnostic.get` / the snacks pickers.
---@return vim.diagnostic.SeverityFilter|nil
function M.severity_filter() return M.min_severity and { min = M.min_severity } or nil end

local RENDERERS = { "virtual_text", "virtual_lines", "underline", "signs" }

---@type table<string, any>
local unfiltered = {}

local function apply()
  local current = vim.diagnostic.config() or {}
  local severity = M.severity_filter()
  local update = {}

  for _, renderer in ipairs(RENDERERS) do
    local value = current[renderer]

    if not severity then
      local saved = unfiltered[renderer]
      unfiltered[renderer] = nil
      -- Undo our own edit and nothing else: a value that is no longer a
      -- filtered table is somebody else's doing now.
      if saved ~= nil and type(value) == "table" and value.severity ~= nil then update[renderer] = saved end
    elseif value == true or type(value) == "table" then
      -- Captured on the way in only. Filtering twice in a row without an
      -- intervening un-filter would otherwise save the already-filtered table
      -- as the thing to restore.
      if unfiltered[renderer] == nil then unfiltered[renderer] = vim.deepcopy(value) end
      local filtered = type(value) == "table" and vim.deepcopy(value) or {}
      filtered.severity = severity
      update[renderer] = filtered
    end
  end

  vim.diagnostic.config(update)
end

--- Show everything, or only errors.
function M.toggle()
  -- Spelled out rather than `x and nil or y`, which in Lua always evaluates to
  -- `y`: `x and nil` is nil, and `nil or y` is y. The filter would never switch
  -- back off.
  if M.min_severity then
    M.min_severity = nil
  else
    M.min_severity = vim.diagnostic.severity.ERROR
  end
  apply()

  if not M.min_severity then
    vim.notify("Showing all diagnostics", vim.log.levels.INFO, { title = "Diagnostics" })
    return
  end

  -- Counted in this buffer rather than the whole session: the number is there
  -- to tell you what just disappeared from the screen in front of you.
  local hidden = #vim.diagnostic.get(0, { severity = { min = vim.diagnostic.severity.WARN } })
  vim.notify(
    hidden > 0 and ("Errors only  (%d hidden in this buffer)"):format(hidden) or "Errors only",
    vim.log.levels.INFO,
    { title = "Diagnostics" }
  )
end

function M.float()
  if vim.api.nvim_win_get_config(0).relative ~= "" then
    vim.cmd.wincmd "p"
    return
  end

  local lnum = vim.api.nvim_win_get_cursor(0)[1] - 1
  local on_line = vim.diagnostic.get(0, { lnum = lnum })
  if vim.tbl_isempty(on_line) then
    vim.notify("Nothing wrong on this line", vim.log.levels.INFO, { title = "Diagnostics" })
    return
  end

  -- Everything on the line is shown, filter or no filter -- but say so, or a
  -- popup listing four things while the gutter shows one looks like a bug.
  local hidden = 0
  if M.min_severity then
    for _, diagnostic in ipairs(on_line) do
      if diagnostic.severity > M.min_severity then hidden = hidden + 1 end
    end
  end

  vim.diagnostic.open_float {
    scope = "line",
    focus = true,
    header = hidden > 0 and { ("Diagnostics:  (%d hidden by the errors-only filter)"):format(hidden), "Bold" }
      or { "Diagnostics:", "Bold" },
  }
end

---@param scope? "buffer" Defaults to the whole project.
function M.picker(scope)
  local picker = require("snacks").picker
  local opts = { severity = M.severity_filter() }
  if scope == "buffer" then
    picker.diagnostics_buffer(opts)
  else
    picker.diagnostics(opts)
  end
end

--- Jump to the next/previous diagnostic the filter is not hiding.
---@param count integer Negative goes backwards. `vim.v.count1` for `3æd`.
function M.jump(count)
  local target = vim.diagnostic.jump { count = count, severity = M.severity_filter(), float = false }
  if not target then
    vim.notify(
      M.min_severity and "No more errors" or "No more diagnostics",
      vim.log.levels.INFO,
      { title = "Diagnostics" }
    )
  end
end

return M
