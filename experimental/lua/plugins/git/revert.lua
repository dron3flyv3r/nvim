local M = {}

local api = vim.api
local NS = api.nvim_create_namespace "git_revert"

---@param message string
---@param level? integer
local function say(message, level) vim.notify(message, level or vim.log.levels.WARN, { title = "Git" }) end

---@param buf integer
---@return boolean
local function is_worktree_buf(buf)
  local name = api.nvim_buf_get_name(buf)
  return vim.bo[buf].buftype == "" and name ~= "" and not name:find("://", 1, true)
end

---@return integer? target, boolean from_worktree
local function diff_target()
  local here = api.nvim_get_current_buf()
  if is_worktree_buf(here) then return here, true end
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    local buf = api.nvim_win_get_buf(win)
    if vim.wo[win].diff and is_worktree_buf(buf) then return buf, false end
  end
end

---@return boolean
local function reachable()
  local lone = require("plugins.git.hud").lone_kind()
  if lone == "new" then
    say "This file is new -- there is nothing to revert to. Delete the file instead"
    return false
  end
  if lone == "gone" then
    say "This file is deleted -- restore it with git, not from the review"
    return false
  end
  if not vim.wo.diff then
    say "Not in a diff window"
    return false
  end
  return true
end

---@param worktree_cmd string what to run when the cursor is in your file
---@param other_cmd string what to run when it is in the old version
---@param what string what "nothing happened" should say you were aiming at
local function apply_revert(worktree_cmd, other_cmd, what)
  if not reachable() then return end

  local target, from_worktree = diff_target()
  if not target then return say "Nothing editable in this diff -- both sides are old revisions" end
  if not vim.bo[target].modifiable then return say "That file is not modifiable" end
  -- Not `readonly`: the review sets that itself to hold the file off disk, so
  -- only the value it found there says anything about the file.
  local review = require "plugins.git.review"
  if not review.track(target) then return say "This is not a working-tree review" end
  if not review.writable(target) then return say "That file is read-only on disk" end

  local before = vim.b[target].changedtick
  -- `silent` because the hold makes Neovim print W10, which arrives dressed as
  -- an error from inside `vim.cmd`.
  local ok, err = pcall(review.mutate, target, function()
    vim.cmd("silent " .. (from_worktree and worktree_cmd or other_cmd))
  end)
  if not ok then return say(tostring(err), vim.log.levels.ERROR) end
  -- Off a change these commands are silent about it, and there would be no
  -- telling that from a key that did nothing.
  if vim.b[target].changedtick == before then return say("No " .. what .. " here -- n / N jump to one") end

  vim.cmd.diffupdate()
end

---@param first integer
---@param last integer
local function revert_lines(first, last)
  local range = ("%d,%d"):format(first, last)
  apply_revert(range .. "diffget", range .. "diffput", "change in those lines")
end

-- `do` and `dp` are Vim's own hunk-sized pair: diff obtain and diff put.
function M.hunk() apply_revert("normal! do", "normal! dp", "change under the cursor") end

function M.line()
  local lnum = api.nvim_win_get_cursor(0)[1]
  revert_lines(lnum, lnum)
end

function M.file() apply_revert("%diffget", "%diffput", "change in this file") end

-- `'<` and `'>` are not set until the selection ends, so the bounds are read
-- while it is still live: `v` is the anchor, `.` is the cursor.
---@return integer first, integer last
local function selection()
  local first, last = vim.fn.line "v", vim.fn.line "."
  if first > last then
    first, last = last, first
  end
  vim.cmd "normal! \27"
  return first, last
end

function M.selection()
  local first, last = selection()
  revert_lines(first, last)
end

function M.undo()
  local target = diff_target()
  if not target then return say "Nothing editable in this diff -- both sides are old revisions" end
  local review = require "plugins.git.review"
  if not review.track(target) then return say "This is not a working-tree review" end
  if not review.changed(target) then return say "Nothing from this review to undo in this file" end
  review.mutate(target, function()
    api.nvim_buf_call(target, function()
      local before = vim.b.changedtick
      local ok, err = pcall(vim.cmd, "silent undo")
      if not ok then return say(tostring(err), vim.log.levels.ERROR) end
      if vim.b.changedtick == before then return say "Nothing left to undo in this file" end
    end)
  end)
  vim.cmd.diffupdate()
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

---@class git.revert.Target
---@field buf integer
---@field old string[]
---@field new string[]
---@field from_worktree boolean

---@return git.revert.Target?
local function target()
  if not reachable() then return nil end

  local worktree, other, crowded = panes()
  if crowded then return say "This is not an ordinary two-pane diff" end
  if not worktree then return say "Nothing editable in this diff -- both sides are old revisions" end
  if not other then return say "Nothing to compare against -- this file is in one pane only" end
  if not vim.bo[worktree].modifiable then return say "That file is not modifiable" end

  local review = require "plugins.git.review"
  if not review.track(worktree) then return say "This is not a working-tree review" end
  if not review.writable(worktree) then return say "That file is read-only on disk" end

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

-- Ranged `:diffget` cannot express either of the two below: it applies whatever
-- Vim's diff finds inside a range, and both need the *complement* of a range --
-- several disjoint hunks, applied without the earlier ones renumbering the later.
---@param t git.revert.Target
---@return integer[][] one {start_old, count_old, start_new, count_new} per hunk
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

-- Joined with a space rather than stripped of whitespace: a formatter rewrapping
-- one call across three lines has to compare equal, while `foo bar` and `foobar`
-- must not.
---@param lines string[]
---@return string
local function squashed(lines) return vim.trim((table.concat(lines, " "):gsub("%s+", " "))) end

-- A hunk with no lines on a side sits *between* two lines there, so there is
-- nothing on it to select, which is why an empty side is never touched.
---@param start integer
---@param count integer
---@param first integer
---@param last integer
---@return boolean
local function touches(start, count, first, last) return count > 0 and start <= last and start + count - 1 >= first end

-- Bottom-up, so the line numbers of the hunks still to come stay valid, and
-- joined into one undo block so `u` is one press however many hunks went.
---@param t git.revert.Target
---@param chosen integer[][] in file order
---@param anchor integer?
local function apply(t, chosen, anchor)
  local mark = anchor and api.nvim_buf_set_extmark(t.buf, NS, math.max(anchor - 1, 0), 0, {}) or nil

  require("plugins.git.review").mutate(t.buf, function()
    for i = #chosen, 1, -1 do
      local start_old, count_old, start_new, count_new = chosen[i][1], chosen[i][2], chosen[i][3], chosen[i][4]
      -- A hunk with nothing on the new side is an insertion point after
      -- `start_new`, not a line at it.
      local from = count_new > 0 and start_new - 1 or start_new
      if i < #chosen then pcall(api.nvim_buf_call, t.buf, function() vim.cmd "undojoin" end) end
      api.nvim_buf_set_lines(t.buf, from, from + count_new, true, slice(t.old, start_old, count_old))
    end
  end)

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

function M.keep_selection()
  local first, last = selection()

  local t = target()
  if not t then return end
  -- Selecting in the old pane would have to mean "revert to these", which is
  -- what <Leader>gr already does there. Keeping is about your own version.
  if not t.from_worktree then
    return say "Select the lines to keep in your own version -- this pane is the old one"
  end

  local all = hunks(t)
  if #all == 0 then return say "No changes in this file" end

  local kept, chosen, anchor = 0, {}, nil
  for _, hunk in ipairs(all) do
    -- A hunk the selection touches at all is kept whole. Splitting one would
    -- claim a line-for-line correspondence that a reflow has destroyed.
    if touches(hunk[3], hunk[4], first, last) then
      kept, anchor = kept + 1, anchor or hunk[3]
    else
      chosen[#chosen + 1] = hunk
    end
  end

  -- Keeping nothing is a whole-file revert, which is `R`. Doing it silently off
  -- a selection that simply missed is the one unrecoverable surprise here.
  if kept == 0 then
    return say "The selection touches no change -- R reverts the whole file if that is what you meant"
  end
  if #chosen == 0 then return say "Nothing to revert -- the selection covers every change in this file" end

  apply(t, chosen, anchor)
  say(("Reverted %d change%s, kept %d"):format(#chosen, #chosen == 1 and "" or "s", kept), vim.log.levels.INFO)
end

function M.unformat()
  local t = target()
  if not t then return end
  local all = hunks(t)
  if #all == 0 then return say "No changes in this file" end

  local chosen = {}
  for _, hunk in ipairs(all) do
    local was, now = slice(t.old, hunk[1], hunk[2]), slice(t.new, hunk[3], hunk[4])
    if squashed(was) == squashed(now) then chosen[#chosen + 1] = hunk end
  end
  if #chosen == 0 then return say "No whitespace-only changes here -- every change in this file alters the text" end

  apply(t, chosen, t.from_worktree and vim.fn.line "." or nil)
  say(
    ("Reverted %d whitespace-only change%s, %d left"):format(#chosen, #chosen == 1 and "" or "s", #all - #chosen),
    vim.log.levels.INFO
  )
end

return M
