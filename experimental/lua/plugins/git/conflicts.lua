local M = {}

local api = vim.api

---@param message string
---@param level? integer
local function say(message, level) vim.notify(message, level or vim.log.levels.WARN, { title = "Git" }) end

-- Every conflict action reads the RESULT pane's cursor, whichever pane or panel
-- has focus, because the region bounds are lines in the file being written.
---@return table? view, integer? bufnr, integer? winid
local function merge_target()
  local ok, lib = pcall(require, "diffview.lib")
  local found, view = pcall(function() return ok and lib.get_current_view() or nil end)
  local layout = found and view and view.cur_layout or nil
  local main = layout and layout.get_main_win and layout:get_main_win()
  local bufnr = main and main.file and main.file.bufnr
  if not (view and main and main:is_valid() and bufnr and api.nvim_buf_is_valid(bufnr)) then return end
  return view, bufnr, main.id
end

---@param bufnr integer
---@param winid integer
---@return table?
local function conflict_under(bufnr, winid)
  local parse = require("diffview.vcs.utils").parse_conflicts
  local ok, _, current = pcall(parse, api.nvim_buf_get_lines(bufnr, 0, -1, false), winid)
  return ok and current or nil
end

---@param region table
---@param field "ours"|"base"|"theirs"
---@return integer
local function side_length(region, field)
  local side = region[field]
  return side and side.content and #side.content or 0
end

---@type table<string, git.hud.Took>
local TOOK = { ours = "ours", theirs = "theirs", all = "both", none = "dropped" }

---@param side "ours"|"theirs"|"all"|"none"
---@param whole? boolean the whole file rather than the conflict under the cursor
---@return fun()
function M.take(side, whole)
  return function()
    local actions = require "diffview.actions"
    local review = require "plugins.git.review"

    -- `conflict_choose_all` is asynchronous and resolves every region at once,
    -- so the positions to mark are gone by the time it returns -- and a
    -- whole-file take is one decision, which the counter already reports.
    if whole then
      local _, target = merge_target()
      return review.mutate(target or -1, function() actions.conflict_choose_all(side)() end, true)
    end

    local _, bufnr, winid = merge_target()
    if not bufnr then return say "Not in a merge" end
    local region = conflict_under(bufnr, winid)
    if not region then return say "No conflict under the cursor -- n and N jump to one" end

    local produced = 0
    if side == "ours" or side == "all" then produced = produced + side_length(region, "ours") end
    if side == "all" then produced = produced + side_length(region, "base") end
    if side == "theirs" or side == "all" then produced = produced + side_length(region, "theirs") end

    review.mutate(bufnr, function()
      actions.conflict_choose(side)()
      require("plugins.git.hud").mark(bufnr, region.first, produced, TOOK[side])
    end)
  end
end

-- By line number rather than by looking like a marker: a row of equals signs is
-- a heading in Markdown and a separator only inside a conflict region.
---@param region table
---@return table<integer, boolean>
local function marker_lines(region)
  local lines = {}
  for _, side in ipairs { "ours", "base", "theirs" } do
    local at = region[side] and region[side].first
    if at then lines[at] = true end
  end
  lines[region.last] = true
  return lines
end

-- Part of a side: the lines are copied in above the markers and the region is
-- left standing, so takes add up until `X` drops the rest. Taken as *text*,
-- which is why this works from either side pane without mapping its line
-- numbers onto the file being written.
---@param visual boolean
---@return fun()
function M.take_lines(visual)
  return function()
    local first, last = vim.fn.line ".", vim.fn.line "."
    if visual then
      first, last = vim.fn.line "v", vim.fn.line "."
      if first > last then
        first, last = last, first
      end
      vim.cmd "normal! \27"
    end

    local _, bufnr, winid = merge_target()
    if not bufnr then return say "Not in a merge" end
    local region = conflict_under(bufnr, winid)
    if not region then return say "No conflict under the cursor -- n and N jump to one" end

    -- Only the file being written has markers in it; the side panes are the
    -- clean versions from the index, so everything selected there is content.
    local source = api.nvim_get_current_buf()
    local skip = source == bufnr and marker_lines(region) or {}
    local taken = {}
    for offset, line in ipairs(api.nvim_buf_get_lines(source, first - 1, last, false)) do
      if not skip[first + offset - 1] then taken[#taken + 1] = line end
    end
    if #taken == 0 then return say "Nothing there but conflict markers" end

    require("plugins.git.review").mutate(bufnr, function()
      api.nvim_buf_set_lines(bufnr, region.first - 1, region.first - 1, false, taken)
      require("plugins.git.hud").mark(bufnr, region.first, #taken, "lines")
    end)
    -- Back onto the region's own first line, so the next take and the `X` that
    -- ends it still act on this conflict.
    pcall(api.nvim_win_set_cursor, winid, { region.first + #taken, 0 })
    vim.cmd.diffupdate()
    say(
      ("Took %d line%s -- X drops the rest of this conflict"):format(#taken, #taken == 1 and "" or "s"),
      vim.log.levels.INFO
    )
  end
end

---@param reverse boolean
---@return fun()
function M.nav_resolution(reverse)
  return function()
    local _, bufnr, winid = merge_target()
    if not bufnr then return say "Not in a merge" end
    local list = require("plugins.git.hud").resolutions(bufnr)
    if #list == 0 then return say "Nothing resolved in this file yet" end

    local lnum = api.nvim_win_get_cursor(winid)[1]
    local at
    for index, mark in ipairs(list) do
      if reverse then
        if mark.lnum < lnum then at = index end
      elseif mark.lnum > lnum and not at then
        at = index
      end
    end
    -- Wrapping, and saying so: a file has few resolutions and stopping at the
    -- last one just means pressing the other key to get back.
    local wrapped = at == nil
    at = at or (reverse and #list or 1)

    api.nvim_set_current_win(winid)
    api.nvim_win_set_cursor(winid, { math.min(list[at].lnum, api.nvim_buf_line_count(bufnr)), 0 })
    say(
      ("Resolution %d/%d -- %s%s"):format(at, #list, list[at].took, wrapped and " (wrapped)" or ""),
      vim.log.levels.INFO
    )
  end
end

---@param reverse boolean
---@return fun()
function M.nav_conflict(reverse)
  return function()
    local actions = require "diffview.actions"
    if reverse then
      actions.prev_conflict()
    else
      actions.next_conflict()
    end
  end
end

function M.next_file()
  if require("plugins.git.hud").next_conflict_file() then return end
  require("diffview.actions").select_next_entry()
end

-- `do` and `dp` have to be told which buffer when three of them are in diff
-- mode, so the revert keys cannot mean anything during a merge.
---@param whole boolean
---@return fun()
function M.hint(whole)
  return function()
    say(
      whole and "This is a merge -- gH takes ours for the whole file, gL takes theirs, gB takes both"
        or "This is a merge -- H takes ours, L takes theirs, B takes both, X drops both"
    )
  end
end

local ANCESTOR_NS = api.nvim_create_namespace "git_ancestor"

---@param haystack string[]
---@param needle string[]
---@param near integer
---@return integer?
local function find_block(haystack, needle, near)
  if #needle == 0 or #needle > #haystack then return nil end
  local best
  for start = 1, #haystack - #needle + 1 do
    local match = true
    for offset, line in ipairs(needle) do
      if haystack[start + offset - 1] ~= line then
        match = false
        break
      end
    end
    -- The same block can appear more than once; the copy nearest to where the
    -- region sits in the file being written is the one it came from.
    if match and (not best or math.abs(start - near) < math.abs(best - near)) then best = start end
  end
  return best
end

-- The measured off-by-ones, the same ones `revert.lua` encodes: a hunk with a
-- zero count on one side reports the line it sits *after* on that side.
---@param hunks integer[][]
---@param first integer
---@param last integer
---@return integer from, integer to
local function to_ancestor(hunks, first, last)
  local offset, from, to = 0, nil, nil
  for _, hunk in ipairs(hunks) do
    local start_old, count_old, start_new, count_new = hunk[1], hunk[2], hunk[3], hunk[4]
    if count_new == 0 then
      if start_new < first then offset = offset + count_old end
    elseif start_new + count_new - 1 < first then
      offset = offset + count_old - count_new
    elseif start_new <= last and count_old > 0 then
      from = math.min(from or start_old, start_old)
      to = math.max(to or start_old, start_old + count_old - 1)
    end
  end
  if from then return from, to end
  return first + offset, last + offset
end

---@param view table
---@param stage integer
---@param path string
---@return string[]?
local function stage_lines(view, stage, path)
  local out, code = view.adapter:exec_sync({ "show", (":%d:%s"):format(stage, path) }, view.adapter.ctx.toplevel)
  if type(out) ~= "table" or code ~= 0 or #out == 0 or (#out == 1 and out[1] == "") then return nil end
  return out
end

-- Which lines of the ancestor this region grew out of. OURS first, falling back
-- to THEIRS for a region whose own side deleted everything. Read from the index
-- rather than from the side panes: Diffview loads those lazily, so a pane can
-- still be empty when the key is pressed.
---@param view table
---@param entry table
---@param region table
---@param base string[]
---@return integer? from, integer? to
local function ancestor_range(view, entry, region, base)
  local base_text = table.concat(base, "\n") .. "\n"
  for _, side in ipairs { { "ours", 2 }, { "theirs", 3 } } do
    local content = region[side[1]] and region[side[1]].content or {}
    local lines = #content > 0 and stage_lines(view, side[2], entry.path) or nil
    local at = lines and find_block(lines, content, region.first) or nil
    if at then
      local hunks = vim.diff(base_text, table.concat(lines, "\n") .. "\n", { result_type = "indices" }) or {}
      return to_ancestor(hunks, at, at + #content - 1)
    end
  end
end

---@param entry table
---@param base string[]
---@param from integer?
---@param to integer?
---@param position string
local function ancestor_float(entry, base, from, to, position)
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, base)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = vim.filetype.match { filename = entry.path } or ""
  local width = math.min(110, math.max(60, vim.o.columns - 10))
  local height = math.min(#base + 1, math.floor(vim.o.lines * 0.7))
  -- A float rather than a split: a new window inside the layout is a window
  -- Diffview will try to make part of the diff.
  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = (" BASE -- %s%s "):format(entry.path, position),
    title_pos = "center",
    footer = " q close  ·  <CR> take these lines ",
    footer_pos = "center",
  })
  -- `minimal` turns both of these off, and which lines these are is the point.
  vim.wo[win].number = true
  vim.wo[win].signcolumn = "yes:1"
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false

  if from then
    for lnum = from, math.min(to or from, #base) do
      api.nvim_buf_set_extmark(buf, ANCESTOR_NS, lnum - 1, 0, {
        sign_text = "▌",
        sign_hl_group = "GitHudMark",
        number_hl_group = "GitHudMark",
      })
    end
    api.nvim_win_set_cursor(win, { math.min(from, #base), 0 })
    api.nvim_win_call(win, function() vim.cmd "normal! zz" end)
  end

  vim.keymap.set("n", "q", "<Cmd>close<CR>", { buffer = buf, nowait = true, desc = "Close the ancestor" })
  vim.keymap.set("n", "<CR>", M.take_lines(false), { buffer = buf, desc = "Take this line into the conflict" })
  vim.keymap.set("x", "<CR>", M.take_lines(true), { buffer = buf, desc = "Take these lines into the conflict" })
end

-- BASE is what both sides started from, and `diff3_horizontal` never has it on
-- screen. A preview rather than a take: `merge.conflictStyle` defaults to `merge`
-- and writes no `|||||||` section, so stage 1 is read instead of guessed at, and
-- taking from it is `<CR>` in the float -- the same accumulating take the side
-- panes have, rather than a second spelling of "replace this region".
function M.show_base()
  local view = require("diffview.lib").get_current_view()
  local layout = view and view.cur_layout
  local main = layout and layout.get_main_win and layout:get_main_win()
  local entry = view and view.cur_entry
  local bufnr = main and main.file and main.file.bufnr
  if not (entry and bufnr and api.nvim_buf_is_valid(bufnr)) then return say "Not in a merge" end

  local parse = require("diffview.vcs.utils").parse_conflicts
  local ok, list, current = pcall(parse, api.nvim_buf_get_lines(bufnr, 0, -1, false), main.id)
  if not (ok and current) then return say "No conflict under the cursor -- n and N jump to one" end

  local base = stage_lines(view, 1, entry.path)
  if not base then return say "No common ancestor to show -- both sides added this file" end

  list = type(list) == "table" and list or {}
  local index = 0
  for at, region in ipairs(list) do
    if region.first == current.first then index = at end
  end

  local from, to = ancestor_range(view, entry, current, base)
  ancestor_float(entry, base, from, to, #list > 1 and (" -- region %d/%d"):format(index, #list) or "")
  if not from then say "This region could not be traced back to the ancestor, so it is shown whole" end
end

return M
