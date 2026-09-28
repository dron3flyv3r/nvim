local M = {}

local api = vim.api

-- In the order it is dropped when the window is too narrow: the last entry goes
-- first, so what survives is the half of the line that moves you around.
---@type { keys: string, what: string, mode: string }[]
local HINTS = {
  { keys = "n/N", what = "change", mode = "diff finish" },
  { keys = "n/N", what = "conflict", mode = "merge" },
  { keys = "H", what = "ours", mode = "merge" },
  { keys = "L", what = "theirs", mode = "merge" },
  { keys = "B", what = "both", mode = "merge" },
  { keys = "X", what = "drop", mode = "merge" },
  { keys = "<CR>", what = "take line", mode = "merge" },
  { keys = "r/R", what = "revert", mode = "diff" },
  { keys = "gk/gw", what = "keep/unfmt", mode = "diff" },
  { keys = "]r/[r", what = "check", mode = "merge" },
  { keys = "<Leader>cb", what = "base", mode = "merge" },
  { keys = "<Tab>", what = "file", mode = "diff finish" },
  { keys = "<Tab>", what = "next file", mode = "merge" },
  { keys = "gf", what = "edit", mode = "diff finish" },
  { keys = "u", what = "undo", mode = "diff merge" },
  { keys = "q", what = "finish", mode = "diff merge" },
  { keys = "q", what = "commit this", mode = "finish" },
  { keys = "zM/zR", what = "folds", mode = "diff finish" },
  { keys = "F1", what = "all keys", mode = "all" },
  { keys = "?", what = "hide this", mode = "all" },
}

-- Remembered for the session rather than saved: it is "yes, I know these now"
-- for the review you are in, not a permanent preference.
local hidden = false

---@type { showtabline: integer, tabline: string }?
local saved

local function set_highlights()
  local normal = api.nvim_get_hl(0, { name = "Normal", link = false })
  local comment = api.nvim_get_hl(0, { name = "Comment", link = false })
  local special = api.nvim_get_hl(0, { name = "Special", link = false })
  api.nvim_set_hl(0, "GitKeysLine", { bg = normal.bg, fg = comment.fg })
  api.nvim_set_hl(0, "GitKeysKey", { bg = normal.bg, fg = special.fg, bold = true })
end

---@param mode "diff"|"merge"|"finish"
---@param width integer
---@return string
local function compose(mode, width)
  local chosen = {}
  for _, hint in ipairs(HINTS) do
    if hint.mode == "all" or hint.mode:find(mode, 1, true) then chosen[#chosen + 1] = hint end
  end

  local plain, parts
  repeat
    plain, parts = " ", { "%#GitKeysLine# " }
    for _, hint in ipairs(chosen) do
      plain = ("%s%s %s   "):format(plain, hint.keys, hint.what)
      parts[#parts + 1] = ("%%#GitKeysKey#%s%%#GitKeysLine# %s   "):format(hint.keys, hint.what)
    end
    if #vim.trim(plain) + 1 <= width or #chosen <= 3 then break end
    table.remove(chosen)
  until false
  parts[#parts + 1] = "%="
  return table.concat(parts)
end

local function close()
  if not saved then return end
  vim.o.tabline = saved.tabline
  vim.o.showtabline = saved.showtabline
  saved = nil
end

---@return boolean
local function reviewing()
  local ok, lib = pcall(require, "diffview.lib")
  if not ok then return false end
  local found, view = pcall(lib.get_current_view)
  return found and view ~= nil
end

-- The tabline rather than a float or a window: a float covered the last row of
-- every pane, and a real window is one Diffview would fold into the layout.
---@param mode "diff"|"merge"|"finish"
local function draw(mode)
  if hidden or not reviewing() then return close() end
  saved = saved or { showtabline = vim.o.showtabline, tabline = vim.o.tabline }
  vim.o.tabline = compose(mode, vim.o.columns)
  vim.o.showtabline = 2
end

---@param kind string the pane kind from `plugins.git.hud`
function M.show(kind)
  local mode = "diff"
  if kind == "ours" or kind == "result" or kind == "theirs" then
    mode = "merge"
  elseif kind == "staged" then
    mode = "finish"
  end
  vim.schedule(function() draw(mode) end)
end

function M.hide() close() end

-- `?` inside a review. Reverse search is the only thing this costs, and a review
-- is not where anyone searches backwards.
function M.toggle()
  hidden = not hidden
  if hidden then return close() end
  local hud = require "plugins.git.hud"
  M.show(hud.lone_kind() or hud.current_kind() or "diff")
end

function M.setup()
  set_highlights()
  local group = api.nvim_create_augroup("git_keys", { clear = true })
  api.nvim_create_autocmd("ColorScheme", {
    group = group,
    desc = "Rebuild the review legend colours",
    callback = set_highlights,
  })
  api.nvim_create_autocmd({ "VimResized", "TabEnter" }, {
    group = group,
    desc = "Show the review legend only in the tab holding the review",
    callback = function()
      if not reviewing() then return close() end
      M.show(require("plugins.git.hud").current_kind() or "diff")
    end,
  })
end

return M
