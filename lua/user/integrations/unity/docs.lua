-- `K` for the Unity API: opening the Scripting Reference page for the symbol
-- under the cursor.
--
-- WHY THIS IS NOT JUST HOVER. `roslyn_ls`'s hover shows you the signature and
-- whatever XML doc comment the assembly shipped with, and Unity's assemblies
-- ship with almost none -- hover `Rigidbody.AddForce` and you get the overload
-- list and nothing about what a ForceMode actually does. The Scripting
-- Reference has the prose, the code example and the "see also"; it is where you
-- were going to end up anyway.
--
-- LOCAL DOCS FIRST. The Unity Hub can install the documentation alongside an
-- editor, and if it is there it is both faster and exactly the right version --
-- the API moved a lot between 2021 and 6000. Failing that, fall back to
-- docs.unity3d.com pinned to the project's version, because the unversioned URL
-- redirects to whatever is current and will happily show you a method that does
-- not exist in your editor.

local M = {}

--- The symbol to look up: `Rigidbody` on its own, or `Rigidbody.AddForce` when
--- the cursor is on a member.
---
--- Walked out of the line text rather than asked of the language server,
--- because the answer wanted here is the *documented* name -- the type and the
--- member as the reference indexes them -- not the resolved symbol, and a
--- dotted chain is exactly what the URL needs.
---@return string|nil
function M.symbol_at_cursor()
  local word = vim.fn.expand "<cword>"
  if word == "" or not word:match "^[%a_][%w_]*$" then return nil end

  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1

  -- Find where this word starts, then look at what is immediately left of it.
  local start = col
  while start > 1 and line:sub(start - 1, start - 1):match "[%w_]" do
    start = start - 1
  end
  if line:sub(start - 1, start - 1) ~= "." then return word end

  local before = line:sub(1, start - 2)
  local owner = before:match "([%a_][%w_]*)%s*$"
  -- A lower-case owner is a local or a field (`transform.position`), and the
  -- reference is indexed by type, so there is nothing useful to prepend.
  if owner and owner:match "^%u" then return owner .. "." .. word end
  return word
end

--- Where the docs for this project live, local or remote.
---@param root string
---@param symbol string
---@return string target A file path or a URL.
---@return boolean local_docs
function M.url(root, symbol)
  local unity = require "user.integrations.unity"
  local exe, version = unity.editor_exe(root)

  if exe then
    -- `<editor>/Editor/Unity` -> `<editor>/Editor/Data/Documentation/en/...`
    local data = vim.fs.dirname(exe) .. "/Data/Documentation/en/ScriptReference/" .. symbol .. ".html"
    if vim.fn.filereadable(data) == 1 then return data, true end
  end

  -- Docs URLs take the major.minor of the version -- `6000.3.14f1` -> `6000.3`.
  local short = version and version:match "^(%d+%.%d+)"
  if short then
    return ("https://docs.unity3d.com/%s/Documentation/ScriptReference/%s.html"):format(short, symbol), false
  end
  return ("https://docs.unity3d.com/ScriptReference/%s.html"):format(symbol), false
end

--- Open the Scripting Reference for the symbol under the cursor.
function M.open()
  local root = require("user.integrations.unity").require_root()
  if not root then return end

  local symbol = M.symbol_at_cursor()
  if not symbol then
    vim.notify("No symbol under the cursor", vim.log.levels.WARN, { title = "Unity" })
    return
  end

  local target, local_docs = M.url(root, symbol)
  -- `vim.ui.open` is the right door for both: it hands a path to the desktop
  -- handler and a URL to the browser, and respects whatever the user has set.
  vim.ui.open(target)
  vim.notify(
    ("%s -- %s docs"):format(symbol, local_docs and "local" or "docs.unity3d.com"),
    vim.log.levels.INFO,
    { title = "Unity" }
  )
end

return M
