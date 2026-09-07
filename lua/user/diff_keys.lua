--- The legend along the bottom of a review. The keys are learnable but not
--- guessable, and `g?` lists all of Diffview's own without saying which of them
--- this config replaced. One line, the keys for the mode you are actually in,
--- and `?` to put it away once you no longer need it.
local M = {}

local api = vim.api

--- What each mode's line says, in the order it is dropped when the window is
--- too narrow: the last entry goes first. `mode` lists the modes an entry
--- belongs to -- "diff", "merge", "finish" -- or "all" for every one of them.
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
  { keys = "]r/[r", what = "check", mode = "merge" },
  { keys = "<Tab>", what = "file", mode = "diff finish" },
  { keys = "<Tab>", what = "next file", mode = "merge" },
  { keys = "u", what = "undo", mode = "diff merge" },
  { keys = "q", what = "finish", mode = "diff merge" },
  { keys = "q", what = "commit this", mode = "finish" },
  { keys = "zM/zR", what = "folds", mode = "diff finish" },
  { keys = "F1", what = "all keys", mode = "all" },
  { keys = "?", what = "hide this", mode = "all" },
}

local NS = api.nvim_create_namespace "user_diff_keys"

--- Remembered for the session rather than saved: it is a "yes, I know these
--- now" for the review you are in, not a permanent preference.
local hidden = false

---@type integer? window, integer? buffer
local win, buf

local function set_highlights()
  local normal = api.nvim_get_hl(0, { name = "Normal", link = false })
  local comment = api.nvim_get_hl(0, { name = "Comment", link = false })
  local special = api.nvim_get_hl(0, { name = "Special", link = false })
  api.nvim_set_hl(0, "DiffKeysLine", { bg = normal.bg, fg = comment.fg })
  api.nvim_set_hl(0, "DiffKeysKey", { bg = normal.bg, fg = special.fg, bold = true })
end

---@param mode "diff"|"merge"|"finish"
---@param width integer
---@return string line, integer[][] key column ranges
local function compose(mode, width)
  local chosen = {}
  for _, hint in ipairs(HINTS) do
    if hint.mode == "all" or hint.mode:find(mode, 1, true) then chosen[#chosen + 1] = hint end
  end

  -- Drop from the end until it fits, so what survives on a narrow screen is
  -- the half of the line that moves you around.
  local line, spans
  repeat
    line, spans = " ", {}
    for _, hint in ipairs(chosen) do
      spans[#spans + 1] = { #line, #line + #hint.keys }
      line = ("%s%s %s   "):format(line, hint.keys, hint.what)
    end
    line = line:gsub("%s+$", "")
    if #line <= width or #chosen <= 3 then break end
    table.remove(chosen)
  until false
  return line, spans
end

local function close()
  if win and api.nvim_win_is_valid(win) then api.nvim_win_close(win, true) end
  win = nil
end

---@return boolean whether a review is on screen in this tab
local function reviewing()
  local ok, lib = pcall(require, "diffview.lib")
  if not ok then return false end
  local found, view = pcall(lib.get_current_view)
  return found and view ~= nil
end

---@param mode "diff"|"merge"|"finish"
local function draw(mode)
  if hidden or not reviewing() then return close() end

  if not (buf and api.nvim_buf_is_valid(buf)) then
    buf = api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "hide"
  end

  local width = vim.o.columns
  local line, spans = compose(mode, width)
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, { line })
  vim.bo[buf].modifiable = false
  api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  for _, span in ipairs(spans) do
    if span[2] <= #line then
      api.nvim_buf_set_extmark(buf, NS, 0, span[1], { end_col = span[2], hl_group = "DiffKeysKey" })
    end
  end

  -- One row above the statusline, overlaying the panes rather than shrinking
  -- them: a real window here is a window Diffview would fold into the layout.
  -- `scrolloff` keeps the cursor well clear of the row this covers.
  local config = {
    relative = "editor",
    row = vim.o.lines - 2 - (vim.o.cmdheight or 0),
    col = 0,
    width = width,
    height = 1,
    style = "minimal",
    focusable = false,
    zindex = 40,
  }
  if win and api.nvim_win_is_valid(win) then
    api.nvim_win_set_config(win, config)
  else
    config.noautocmd = true
    win = api.nvim_open_win(buf, false, config)
  end
  vim.wo[win].winhighlight = "Normal:DiffKeysLine"
end

---Called for each pane as Diffview dresses it.
---@param kind string the pane kind from `diff_hud`
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

---`?` inside a review. Reverse search is the only thing this costs, and a
---review is not where anyone searches backwards.
function M.toggle()
  hidden = not hidden
  if hidden then return close() end
  local hud = require "user.diff_hud"
  M.show(hud.lone_kind() or hud.current_kind() or "diff")
end

set_highlights()
local group = api.nvim_create_augroup("user_diff_keys", { clear = true })
api.nvim_create_autocmd("ColorScheme", {
  group = group,
  desc = "Rebuild the review legend colors",
  callback = set_highlights,
})
api.nvim_create_autocmd({ "VimResized", "TabEnter" }, {
  group = group,
  desc = "Keep the review legend on the bottom row of the tab that has the review",
  callback = function()
    if not reviewing() then return close() end
    local hud = require "user.diff_hud"
    M.show(hud.current_kind() or "diff")
  end,
})
-- A float in a saved session comes back as an ordinary window in the wrong
-- place, so it is never part of one.
api.nvim_create_autocmd("User", {
  group = group,
  pattern = "SessionSavePre",
  desc = "Never store the review legend in a session",
  callback = close,
})

return M
