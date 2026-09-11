--- Two reverts that neither `r` (one change) nor `R` (the whole file) can say:
--- keep the lines you selected and roll back everything else in the file, and
--- roll back only what a formatter did on its own.
local M = {}

local api = vim.api
local NS = api.nvim_create_namespace "user_diff_revert"

---@param msg string
---@param level? integer
local function notify(msg, level) require("astrocore").notify(msg, level or vim.log.levels.WARN, { title = "Git" }) end

---@param buf integer
---@return boolean
local function is_worktree_buf(buf)
  local name = api.nvim_buf_get_name(buf)
  return vim.bo[buf].buftype == "" and name ~= "" and not name:find("://", 1, true)
end

---@return integer? worktree, integer? other, boolean crowded
local function panes()
  local worktree, other, crowded = nil, nil, false
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    if vim.wo[win].diff then
      local buf = api.nvim_win_get_buf(win)
      if is_worktree_buf(buf) then
        if worktree and worktree ~= buf then crowded = true end
        worktree = worktree or buf
      else
        if other and other ~= buf then crowded = true end
        other = other or buf
      end
    end
  end
  return worktree, other, crowded
end

---@class DiffRevertTarget
---@field buf integer the file being edited
---@field old string[] the version being compared against
---@field new string[] the lines currently in the buffer
---@field from_worktree boolean whether the cursor is in the editable pane

---The two sides of an ordinary diff, behind the guards every revert shares.
---@return DiffRevertTarget?
local function target()
  local lone = require("user.diff_hud").lone_kind()
  if lone == "new" then return notify "This file is new -- there is nothing to revert to. Delete the file instead" end
  if lone == "gone" then return notify "This file is deleted -- restore it with git, not from the review" end
  if not vim.wo.diff then return notify "Not in a diff window" end

  local worktree, other, crowded = panes()
  if crowded then return notify "This is not an ordinary two-pane diff" end
  if not worktree then return notify "Nothing editable in this diff -- both sides are old revisions" end
  if not other then return notify "Nothing to compare against -- this file is in one pane only" end
  if not vim.bo[worktree].modifiable then return notify "That file is not modifiable" end

  -- Not `readonly`: the review sets that itself to hold the file back from
  -- disk, so only the value it found there says anything about the file.
  local review = require "user.diff_review"
  if not review.track(worktree) then return notify "This is not a working-tree review" end
  if not review.writable(worktree) then return notify "That file is read-only on disk" end

  return {
    buf = worktree,
    old = api.nvim_buf_get_lines(other, 0, -1, true),
    new = api.nvim_buf_get_lines(worktree, 0, -1, true),
    from_worktree = api.nvim_get_current_buf() == worktree,
  }
end

---@param lines string[]
---@return string
local function text(lines) return table.concat(lines, "\n") .. "\n" end

---@param t DiffRevertTarget
---@return integer[][] one {start_old, count_old, start_new, count_new} per hunk, in file order
local function hunks(t) return vim.diff(text(t.old), text(t.new), { result_type = "indices" }) or {} end

---@param lines string[]
---@param start integer
---@param count integer
---@return string[]
local function slice(lines, start, count)
  local out = {}
  for i = start, start + count - 1 do
    out[#out + 1] = lines[i]
  end
  return out
end

---Joined with a space rather than stripped of whitespace: a formatter rewrapping
---one call across three lines has to compare equal, while `foo bar` and `foobar`
---must not.
---@param lines string[]
---@return string
local function squashed(lines) return vim.trim((table.concat(lines, " "):gsub("%s+", " "))) end

---A hunk with no lines on a side sits *between* two lines there, so there is
---nothing on it to select -- which is why an empty side is never touched.
---@param start integer
---@param count integer
---@param first integer
---@param last integer
---@return boolean
local function touches(start, count, first, last) return count > 0 and start <= last and start + count - 1 >= first end

---Bottom-up, so the line numbers of the hunks still to come stay valid, and
---joined into one undo block so `u` is one press however many hunks went.
---@param t DiffRevertTarget
---@param chosen integer[][] the hunks to revert, in file order
---@param anchor integer? a line to keep the cursor on across the edit
local function apply(t, chosen, anchor)
  local mark = anchor and api.nvim_buf_set_extmark(t.buf, NS, math.max(anchor - 1, 0), 0, {}) or nil

  for i = #chosen, 1, -1 do
    local start_old, count_old, start_new, count_new = chosen[i][1], chosen[i][2], chosen[i][3], chosen[i][4]
    -- A hunk with nothing on the new side is an insertion point after
    -- `start_new`, not a line at it.
    local from = count_new > 0 and start_new - 1 or start_new
    if i < #chosen then pcall(api.nvim_buf_call, t.buf, function() vim.cmd "undojoin" end) end
    api.nvim_buf_set_lines(t.buf, from, from + count_new, true, slice(t.old, start_old, count_old))
  end

  if mark then
    local pos = api.nvim_buf_get_extmark_by_id(t.buf, NS, mark, {})
    api.nvim_buf_del_extmark(t.buf, NS, mark)
    local win = api.nvim_get_current_win()
    if pos[1] and api.nvim_win_get_buf(win) == t.buf then
      api.nvim_win_set_cursor(win, { math.min(pos[1] + 1, api.nvim_buf_line_count(t.buf)), 0 })
    end
  end
  vim.cmd.diffupdate()
end

---`<Leader>gk` from visual mode. `'<`/`'>` are not set until the selection
---ends, so the bounds are read while it is still live -- `v` is the anchor,
---`.` is the cursor.
function M.keep_selection()
  local first, last = vim.fn.line "v", vim.fn.line "."
  if first > last then
    first, last = last, first
  end
  vim.cmd "normal! \27"

  local t = target()
  if not t then return end
  -- Selecting in the old pane would have to mean "revert to these", which is
  -- what <Leader>gr already does there. Keeping is about your own version.
  if not t.from_worktree then
    return notify "Select the lines to keep in your own version -- this pane is the old one"
  end

  local all = hunks(t)
  if #all == 0 then return notify "No changes in this file" end

  local kept, chosen, anchor = 0, {}, nil
  for _, hunk in ipairs(all) do
    if touches(hunk[3], hunk[4], first, last) then
      kept, anchor = kept + 1, anchor or hunk[3]
    else
      chosen[#chosen + 1] = hunk
    end
  end

  -- Keeping nothing is a whole-file revert, which is `R`. Doing it silently
  -- off a selection that simply missed is the one unrecoverable surprise here.
  if kept == 0 then
    return notify "The selection touches no change -- R reverts the whole file if that is what you meant"
  end
  if #chosen == 0 then return notify "Nothing to revert -- the selection covers every change in this file" end

  apply(t, chosen, anchor)
  notify(("Reverted %d change%s, kept %d"):format(#chosen, #chosen == 1 and "" or "s", kept), vim.log.levels.INFO)
end

---`<Leader>gw`. A formatter's own work is whitespace, so reverting the hunks
---that are only whitespace leaves the edit you made and nothing else.
function M.unformat()
  local t = target()
  if not t then return end
  local all = hunks(t)
  if #all == 0 then return notify "No changes in this file" end

  local chosen = {}
  for _, hunk in ipairs(all) do
    local was, now = slice(t.old, hunk[1], hunk[2]), slice(t.new, hunk[3], hunk[4])
    if squashed(was) == squashed(now) then chosen[#chosen + 1] = hunk end
  end
  if #chosen == 0 then return notify "No whitespace-only changes here -- every change in this file alters the text" end

  apply(t, chosen, t.from_worktree and vim.fn.line "." or nil)
  notify(
    ("Reverted %d whitespace-only change%s, %d left"):format(#chosen, #chosen == 1 and "" or "s", #all - #chosen),
    vim.log.levels.INFO
  )
end

return M
