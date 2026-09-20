local project = require "lang.unity.project"

local M = {}

---@return string|nil
function M.symbol_at_cursor()
  local word = vim.fn.expand "<cword>"
  if word == "" or not word:match "^[%a_][%w_]*$" then return nil end

  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1

  local start = col
  while start > 1 and line:sub(start - 1, start - 1):match "[%w_]" do
    start = start - 1
  end
  if line:sub(start - 1, start - 1) ~= "." then return word end

  local owner = line:sub(1, start - 2):match "([%a_][%w_]*)%s*$"
  -- A lower-case owner is a local or a field (`transform.position`), and the
  -- reference is indexed by type, so there is nothing useful to prepend.
  if owner and owner:match "^%u" then return owner .. "." .. word end
  return word
end

---@param root string
---@param symbol string
---@return string target A file path or a URL.
---@return boolean local_docs
function M.url(root, symbol)
  local exe, version = project.editor_exe(root)

  if exe then
    local offline = vim.fs.dirname(exe) .. "/Data/Documentation/en/ScriptReference/" .. symbol .. ".html"
    if vim.fn.filereadable(offline) == 1 then return offline, true end
  end

  -- The docs URL takes the major.minor only: `6000.3.14f1` -> `6000.3`.
  local short = version and version:match "^(%d+%.%d+)"
  if short then
    return ("https://docs.unity3d.com/%s/Documentation/ScriptReference/%s.html"):format(short, symbol), false
  end
  return ("https://docs.unity3d.com/ScriptReference/%s.html"):format(symbol), false
end

function M.open()
  local root = project.require_root()
  if not root then return end

  local symbol = M.symbol_at_cursor()
  if not symbol then
    vim.notify("No symbol under the cursor", vim.log.levels.WARN, { title = "Unity" })
    return
  end

  local target, local_docs = M.url(root, symbol)
  vim.ui.open(target)
  vim.notify(
    ("%s -- %s docs"):format(symbol, local_docs and "local" or "docs.unity3d.com"),
    vim.log.levels.INFO,
    { title = "Unity" }
  )
end

return M
