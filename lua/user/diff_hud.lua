--- The reading half of the diff review. `diff_review.lua` decides what may be
--- written; this decides what the two panes look like: which side you are on,
--- where you are in the changeset, whole files instead of fold stubs, and a
--- single pane for a file that only exists on one side.
local M = {}

local api = vim.api

--- Marks left on a resolution, so a finished conflict still says what you did
--- to it. Virtual text and the number column are used rather than a sign or a
--- highlight: a diff background outranks both `CursorLine` and an extmark
--- highlight, and the sign column already has Git's own signs in it.
local MARK_NS = api.nvim_create_namespace "user_diff_hud_marks"

---@alias DiffHudTook "ours"|"theirs"|"both"|"base"|"lines"|"dropped"

---@type table<DiffHudTook, string>
local TOOK = {
  ours = "took ours",
  theirs = "took theirs",
  both = "took both sides",
  base = "took the ancestor",
  lines = "built line by line",
  dropped = "dropped both sides",
}

---@param msg string
local function notify(msg) require("astrocore").notify(msg, vim.log.levels.INFO, { title = "Diff review" }) end

--- A high fold level rather than `foldenable = false`, so `zM` still collapses
--- to the changed regions -- the one thing the folded default is good for.
local OPEN_FOLDS = 99

--- How many event-loop turns to wait for Diffview to finish opening both panes
--- before giving up on hiding the empty one.
local READY_TRIES = 10

local WINBAR = "%{%v:lua.require'user.diff_hud'.winbar()%}"

---@alias DiffHudKind "before"|"yours"|"after"|"new"|"gone"|"empty"|"ours"|"result"|"theirs"|"staged"

--- `from` is the diff highlight the bar borrows its background from. The groups
--- are our own because Diffview remaps `DiffAdd` and friends per window, which
--- would repaint a label meant to say which window you are in.
--- The three merge bars borrow by pane position rather than by meaning, so the
--- colour on the left stays the colour the left pane always has.
local BARS = {
  before = { label = "BEFORE", from = "DiffDelete" },
  yours = { label = "YOURS", from = "DiffAdd" },
  after = { label = "AFTER", from = "DiffChange" },
  new = { label = "NEW FILE", from = "DiffAdd" },
  gone = { label = "DELETED", from = "DiffDelete" },
  empty = { label = "", from = "Normal" },
  ours = { label = "OURS", from = "DiffDelete" },
  result = { label = "RESULT", from = "DiffAdd" },
  theirs = { label = "THEIRS", from = "DiffChange" },
  staged = { label = "STAGED", from = "DiffAdd" },
}

---@class DiffHudPane
---@field kind DiffHudKind
---@field symbol string Diffview's window symbol: "a" is the left side
---@field rev string what this side is: a commit, the index, your files
---@field path string repository-relative path, for when the file panel is hidden
---@field position string? where this file is in the changeset, e.g. "file 2/5"
---@field live boolean whether the right side is your files rather than a commit
---@field bufnr integer
---@field a_buf integer? the left side's buffer, for counting changes
---@field b_buf integer? the right side's buffer, for counting changes
---@field c_buf integer? the third side of a merge, which is THEIRS

---@type table<integer, DiffHudPane>
local panes = {}

---Working files being watched for their last conflict, and how many each had
---when it was last looked at.
---@type table<integer, integer>
local watched = {}

---@param name string
---@return table
local function hl(name) return api.nvim_get_hl(0, { name = name, link = false }) end

local function set_highlights()
  local normal, comment, warn = hl "Normal", hl "Comment", hl "WarningMsg"
  api.nvim_set_hl(0, "DiffHudMark", { fg = hl("Special").fg or comment.fg, bold = true })
  for kind, bar in pairs(BARS) do
    local bg = hl(bar.from).bg or normal.bg
    api.nvim_set_hl(0, "DiffHud" .. kind, { bg = bg, fg = normal.fg, bold = true })
    api.nvim_set_hl(0, "DiffHud" .. kind .. "Dim", { bg = bg, fg = comment.fg })
    api.nvim_set_hl(0, "DiffHud" .. kind .. "Alert", { bg = bg, fg = warn.fg, bold = true })
  end
end

---@return table? view
local function current_view()
  local ok, lib = pcall(require, "diffview.lib")
  if not ok then return nil end
  local found, view = pcall(lib.get_current_view)
  return found and view or nil
end

---@return table? RevType
local function rev_types()
  local ok, rev = pcall(require, "diffview.vcs.rev")
  return ok and rev.RevType or nil
end

---@param file table?
---@return string
local function rev_label(file)
  local rev, types = file and file.rev, rev_types()
  if not (rev and types) then return "" end
  if rev.type == types.LOCAL then return "your files" end
  if rev.type == types.STAGE then return "the index" end
  if rev.type == types.COMMIT then return rev:abbrev(7) or "a commit" end
  return "another revision"
end

---Diffview lays a conflict out as three panes: what your branch says, the
---working file you edit, and what is coming in. A rebase, revert or cherry-pick
---uses the same layout with "ours" and "theirs" swapped in meaning, which is
---why the bars name refs rather than sides.
---@param view table?
---@return table? merge_ctx
local function merge_context(view)
  local entry = view and view.cur_entry
  if not (entry and entry.kind == "conflicting") then return nil end
  return view.merge_ctx or {}
end

---@type table<string, DiffHudKind>
local MERGE_KINDS = { a = "ours", b = "result", c = "theirs" }

---@param side table? one of the merge context's `ours`, `theirs` or `base`
---@return string
local function merge_label(side)
  if type(side) ~= "table" then return "" end
  -- Diffview spells this `rev_names` on `theirs` and `ref_names` elsewhere.
  local names = side.ref_names or side.rev_names
  if names and names ~= "" then return (names:gsub("^HEAD %-> ", "")) end
  return (side.hash or ""):sub(1, 7)
end

---@param view table
---@param symbol string
---@return string? label for a merge side, or nil when this is not one
local function merge_rev(view, symbol)
  local ctx = merge_context(view)
  if not ctx then return nil end
  if symbol == "a" then return merge_label(ctx.ours) end
  if symbol == "c" then return merge_label(ctx.theirs) end
  return nil
end

---@param view table
---@param symbol string
---@return DiffHudKind
local function kind_of(view, symbol)
  if merge_context(view) then return MERGE_KINDS[symbol] or "result" end
  local layout = view.cur_layout
  local window = layout and layout[symbol]
  local types = rev_types()
  local file = window and window.file
  local rev = file and file.rev
  if file and types and rev and rev.type == types.LOCAL and not file.nulled then return "yours" end
  -- The index facing HEAD is the last read of a merge before it is committed.
  if types and rev and rev.type == types.STAGE and symbol ~= "a" then return "staged" end
  return symbol == "a" and "before" or "after"
end

---Position of the current file in the panel's own order, so the number matches
---what walking with `n` or `<Tab>` actually does.
---@param view table
---@return string?
local function file_position(view)
  local panel, entry = view.panel, view.cur_entry
  if not (panel and entry) then return nil end
  local ok, list = pcall(function()
    if panel.ordered_file_list then return panel:ordered_file_list() end
    return panel.list_files and panel:list_files() or nil
  end)
  if not (ok and type(list) == "table") then return nil end
  for index, file in ipairs(list) do
    if file == entry then
      -- A file history of one file lists that file once per commit, so the
      -- number is a position in time there rather than in a changeset.
      return ("%s %d/%d"):format(panel.single_file and "commit" or "file", index, #list)
    end
  end
end

---A merge has two diffs to keep -- ours against the result, and the result
---against theirs -- so one slot is not enough. Dropping the lot once it grows
---costs a recompute nobody can see; tracking buffer lifetimes would cost more.
---@type table<string, { tick: string, value: table }>
local memos = {}
local MEMO_SLOTS = 8

---@param slot string
---@param tick string what invalidates the entry
---@param build fun(): table
---@return table
local function memo(slot, tick, build)
  local hit = memos[slot]
  if hit and hit.tick == tick then return hit.value end
  if vim.tbl_count(memos) >= MEMO_SLOTS then memos = {} end
  local value = build()
  memos[slot] = { tick = tick, value = value }
  return value
end

---@param bufnr integer?
---@return boolean
local function usable(bufnr) return bufnr ~= nil and api.nvim_buf_is_valid(bufnr) and api.nvim_buf_is_loaded(bufnr) end

---@param bufnr integer
---@return string
local function text(bufnr) return table.concat(api.nvim_buf_get_lines(bufnr, 0, -1, true), "\n") .. "\n" end

---The hunks of the current file, recomputed only when one of the two sides
---changes -- the winbar asks for this on every redraw. Vim's own `]c` hunks
---are not enumerable, so this reproduces them with the same diff options.
---@param pane DiffHudPane
---@return integer[][]
local function hunk_list(pane)
  local a, b = pane.a_buf, pane.b_buf
  if not (usable(a) and usable(b)) then return {} end

  local tick = ("%d:%d"):format(vim.b[a].changedtick, vim.b[b].changedtick)
  return memo(("hunks:%d:%d"):format(a, b), tick, function()
    local ok, list = pcall(vim.diff, text(a), text(b), {
      result_type = "indices",
      algorithm = "histogram",
      indent_heuristic = true,
      linematch = 60,
    })
    return (ok and type(list) == "table") and list or {}
  end)
end

---The conflict regions still in a file, from the same parser Diffview's own
---conflict actions use, so the count and the keys can never disagree. A
---resolved region has no markers left, which is why this doubles as "how much
---of this file is unresolved".
---@param bufnr integer?
---@return table[]
local function conflict_list(bufnr)
  if not usable(bufnr) then return {} end
  return memo(("conflicts:%d"):format(bufnr), tostring(vim.b[bufnr].changedtick), function()
    local ok, utils = pcall(require, "diffview.vcs.utils")
    if not ok then return {} end
    local parsed, list = pcall(utils.parse_conflicts, api.nvim_buf_get_lines(bufnr, 0, -1, false))
    return (parsed and type(list) == "table") and list or {}
  end)
end

---@param pane DiffHudPane
---@return integer? index, integer? total
local function change_position(pane)
  local list = hunk_list(pane)
  if #list == 0 then return nil end
  -- `vim.diff` reports each hunk as start/count on both sides; for a pure
  -- insertion or deletion the count on one side is zero and the start is the
  -- line it sits behind, which is still the right line to compare against.
  local field = pane.symbol == "a" and 1 or 3
  local lnum, index = api.nvim_win_get_cursor(0)[1], 1
  for position, hunk in ipairs(list) do
    if hunk[field] <= lnum then index = position end
  end
  return index, #list
end

---Where the cursor is among the conflicts left in the file. Only meaningful in
---the RESULT pane: the region bounds are lines in that buffer, and the other
---two panes sit on different line numbers wherever the sides differ in length.
---@param pane DiffHudPane
---@return integer? index, integer total
local function conflict_position(pane)
  local list = conflict_list(pane.b_buf)
  if #list == 0 then return nil, 0 end
  local lnum, index = api.nvim_win_get_cursor(0)[1], 1
  for position, region in ipairs(list) do
    if (region.first or 0) <= lnum then index = position end
  end
  return index, #list
end

---Line counts taken from the same hunks as the change counter, so a pending
---revert changes them; `git`'s own numbers describe the file on disk.
---@param pane DiffHudPane
---@return string?
local function stats_label(pane)
  local added, removed = 0, 0
  for _, hunk in ipairs(hunk_list(pane)) do
    removed = removed + hunk[2]
    added = added + hunk[4]
  end
  if added == 0 and removed == 0 then return nil end
  return ("+%d -%d"):format(added, removed)
end

---@param value string?
---@return boolean
local function nonempty(value) return value ~= nil and value ~= "" end

---@param value string
---@return string
local function escape(value) return (value:gsub("%%", "%%%%")) end

---Evaluated for every redraw of every diff window. Neovim draws a window's
---winbar with that window current, which is how one expression serves all of
---the panes.
---@return string
function M.winbar()
  local pane = panes[api.nvim_get_current_win()]
  local bar = pane and BARS[pane.kind]
  if not bar then return "" end
  local group = "DiffHud" .. pane.kind

  -- `keep` is what a narrow pane must still show and `extra` is what it may
  -- drop: everything after `%<` is what Vim truncates first.
  local keep, extra = {}, {}
  if pane.kind == "empty" then
    keep[1] = "Nothing left to review -- press q to close"
  elseif pane.kind == "new" then
    keep, extra = { pane.position, escape(pane.path) }, { "new file, nothing to compare against" }
  elseif pane.kind == "gone" then
    keep, extra = { pane.position, escape(pane.path) }, { ("was in %s, gone from your files"):format(pane.rev) }
  elseif pane.kind == "ours" or pane.kind == "theirs" then
    local _, left = conflict_position(pane)
    keep = { pane.rev, left > 0 and ("%d to resolve"):format(left) or "nothing left to resolve" }
    extra = { escape(pane.path) }
  elseif pane.kind == "result" then
    -- A resolved region has no markers, so the total *is* what is left. The
    -- position moves to `extra`: a third of the screen is narrow, and which
    -- conflict you are on matters more than which file, which the panel says.
    local at, left = conflict_position(pane)
    -- The count of other files is put here by `hold` and `dress`, because
    -- working it out means reading the files this review has not opened.
    local files = usable(pane.b_buf) and vim.b[pane.b_buf].diff_hud_left or 0
    local done = files > 0 and ("ALL RESOLVED -- <Tab> next conflicted file (%d left)"):format(files)
      or "ALL RESOLVED -- q to save and stage"
    keep = { at and ("conflict %d/%d"):format(at, left) or done }
    extra = { pane.position, escape(pane.path) }
  elseif pane.kind == "before" then
    -- The left side of a file history is a commit facing another commit, so
    -- nothing there is anyone's pending deletion.
    keep = { pane.rev, stats_label(pane) }
    extra = { pane.live and "lines you deleted still exist here" or "the version this commit changed" }
  else
    local change, changes = change_position(pane)
    keep = { pane.position, change and ("change %d/%d"):format(change, changes) or "no changes left" }
    if pane.kind == "after" or pane.kind == "staged" then keep[#keep + 1] = pane.rev end
    extra = { escape(pane.path) }
  end

  local out = { ("%%#%s# %s"):format(group, bar.label ~= "" and bar.label .. " " or "") }
  local resolved = pane.kind == "result" and select(2, conflict_position(pane)) == 0
  if (pane.kind == "yours" or pane.kind == "result") and usable(pane.bufnr) and vim.bo[pane.bufnr].modified then
    -- Before `%<`, so the one thing a narrow pane must not hide is the fact
    -- that this buffer is holding edits nothing has written yet. A resolved
    -- merge pane already says the same thing in more useful words.
    if not resolved then out[#out + 1] = ("%%#%sAlert# PENDING -- q to save or discard "):format(group) end
  end
  out[#out + 1] = ("%%#%sDim# %s "):format(group, table.concat(vim.tbl_filter(nonempty, keep), "  ·  "))
  out[#out + 1] = "%<"
  local rest = table.concat(vim.tbl_filter(nonempty, extra), "  ·  ")
  if rest ~= "" then out[#out + 1] = (" ·  %s "):format(rest) end
  return table.concat(out) .. "%="
end

---@param layout table
---@return boolean
local function panes_ready(layout)
  for _, window in ipairs(layout.windows) do
    local file = window.file
    if not (window:is_valid() and file and usable(file.bufnr)) then return false end
    if api.nvim_win_get_buf(window.id) ~= file.bufnr then return false end
  end
  return true
end

---The empty side of a file that exists on only one side: added, untracked, or
---deleted. Diffview has no single-pane layout for these outside its merge tool.
---@param layout table
---@return table? empty, table? keep
local function lone_side(layout)
  if not (layout.a and layout.b) or #layout.windows ~= 2 then return nil end
  local empty, keep
  for _, window in ipairs { layout.a, layout.b } do
    local file = window.file
    if file and file.nulled then
      empty = window
    else
      keep = window
    end
  end
  if empty and keep then return empty, keep end
end

---@param view table
---@param tries integer
local function hide_empty_side(view, tries)
  local layout = view.cur_layout
  if not layout or view ~= current_view() then return end
  local empty, keep = lone_side(layout)
  if not (empty and keep) then return end

  -- Closing a window while Diffview is still opening the other one breaks its
  -- scroll sync, which reads every window in the layout without checking.
  if not panes_ready(layout) then
    if tries < READY_TRIES then vim.schedule(function() hide_empty_side(view, tries + 1) end) end
    return
  end

  local pane = panes[keep.id]
  if pane then
    pane.kind = empty == layout.a and "new" or "gone"
    if pane.kind == "gone" then pane.rev = rev_label(keep.file) end
  end
  panes[empty.id] = nil
  -- Diffview rebuilds the layout from the surviving window the next time it
  -- opens a file, so this only lasts as long as this file is on screen.
  pcall(api.nvim_win_close, empty.id, false)
end

local function forget_closed_windows()
  for winid in pairs(panes) do
    if not api.nvim_win_is_valid(winid) then panes[winid] = nil end
  end
  for bufnr in pairs(watched) do
    if not api.nvim_buf_is_valid(bufnr) then watched[bufnr] = nil end
  end
end

---Conflicts left in a file that is not on screen, which is the only version
---there is until Diffview opens it.
---@param entry table
---@return integer
local function entry_conflicts(entry)
  local path = entry.absolute_path or entry.path
  -- By name first: a file resolved earlier in the review is still loaded but
  -- its layout has moved on to another entry, and the copy on disk is the one
  -- that still has the markers in it.
  local bufnr = path and vim.fn.bufnr("^" .. path .. "$") or -1
  if not usable(bufnr) then
    local layout = entry.layout
    local main = layout and layout.get_main_win and layout:get_main_win()
    bufnr = main and main.file and main.file.bufnr or -1
  end
  if usable(bufnr) then return #conflict_list(bufnr) end

  local ok, lines = pcall(vim.fn.readfile, path)
  -- Unreadable counts as unresolved: better to stop on it than to skip past it.
  if not (ok and type(lines) == "table") then return 1 end
  local count = 0
  for _, line in ipairs(lines) do
    if line:find "^<<<<<<<" then count = count + 1 end
  end
  return count
end

---Conflicted files still holding markers. Reads disk for files the review has
---not opened, so it is called when a file is opened or finished rather than
---from the winbar, which runs on every redraw.
---@param view table
---@return integer count, table? first still-conflicted entry
local function remaining(view)
  local count, first = 0, nil
  for _, entry in ipairs(view.files and view.files.conflicting or {}) do
    if entry_conflicts(entry) > 0 then
      count = count + 1
      first = first or entry
    end
  end
  return count, first
end

---The last conflict in a file has just gone. Stopping here rather than jumping
---is deliberate: the resolutions are on screen with their marks, and this is
---the moment to read them. `<Tab>` moves on when you are done.
---@param view table
---@param resolved integer the buffer whose last conflict just went away
local function hold(view, resolved)
  if view ~= current_view() then return end
  local name = vim.fn.fnamemodify(api.nvim_buf_get_name(resolved), ":~:.")
  local left = remaining(view)
  if usable(resolved) then vim.b[resolved].diff_hud_left = left end

  if left > 0 then
    return notify(("%s is resolved -- ]r and [r check it, <Tab> moves to the next of %d"):format(name, left))
  end
  notify(("%s is resolved -- no conflicts left. Press q to save and stage"):format(name))
end

---Watch the working file so finishing one file moves you to the next by
---itself. `TextChangedI` is deliberately not watched: half-typed markers come
---and go, and a jump mid-edit would land the cursor somewhere else.
---@param view table
---@param bufnr integer
local function watch_conflicts(view, bufnr)
  if watched[bufnr] then return end
  watched[bufnr] = #conflict_list(bufnr)

  api.nvim_create_autocmd("TextChanged", {
    group = api.nvim_create_augroup("diff_hud_conflicts", { clear = false }),
    buffer = bufnr,
    desc = "Move on when the last conflict in a file is resolved",
    callback = function()
      if not usable(bufnr) then return true end
      local left, before = #conflict_list(bufnr), watched[bufnr] or 0
      watched[bufnr] = left
      if left == 0 and before > 0 then vim.schedule(function() hold(view, bufnr) end) end
    end,
  })
end

---`BufWinEnter` on the null buffer, which is the whole view once every file in
---a review has been reverted.
---@param winid integer
function M.dress_empty(winid)
  panes[winid] = { kind = "empty", symbol = "b", rev = "", path = "", bufnr = api.nvim_win_get_buf(winid) }
  vim.wo[winid].winbar = WINBAR
end

---Diffview's `diff_buf_win_enter` hook, once per pane.
---@param bufnr integer
---@param winid integer
---@param ctx { symbol: string, layout_name: string }
function M.dress(bufnr, winid, ctx)
  forget_closed_windows()
  local view = current_view()
  if not view then return end

  local entry = view.cur_entry
  if entry and entry.path == "null" then return M.dress_empty(winid) end

  local layout = view.cur_layout
  local window = layout and layout[ctx.symbol]
  local pane = {
    kind = kind_of(view, ctx.symbol),
    symbol = ctx.symbol,
    rev = merge_rev(view, ctx.symbol) or rev_label(window and window.file),
    path = entry and entry.path or vim.fn.fnamemodify(api.nvim_buf_get_name(bufnr), ":~:."),
    position = file_position(view),
    live = kind_of(view, "b") == "yours",
    bufnr = bufnr,
    a_buf = layout and layout.a and layout.a.file and layout.a.file.bufnr or nil,
    b_buf = layout and layout.b and layout.b.file and layout.b.file.bufnr or nil,
    c_buf = layout and layout.c and layout.c.file and layout.c.file.bufnr or nil,
  }
  panes[winid] = pane
  vim.wo[winid].winbar = WINBAR
  vim.wo[winid].foldlevel = OPEN_FOLDS

  if pane.kind == "result" and usable(pane.b_buf) then
    watch_conflicts(view, pane.b_buf)
    vim.b[pane.b_buf].diff_hud_left = remaining(view)
  end

  -- "b" is the last pane Diffview opens, so by now both files are known and
  -- one scheduled check is enough for the whole file entry.
  if ctx.symbol == "b" and ctx.layout_name:find "^diff2" then vim.schedule(function() hide_empty_side(view, 1) end) end
end

---Conflicts left in a buffer. The review asks before it writes: a file with
---markers still in it is not a resolution.
---@param bufnr integer
---@return integer
function M.conflicts(bufnr) return #conflict_list(bufnr) end

---Conflicts left in one entry of the changeset, whether or not the review has
---opened it. Leaving a merge at a file has to ask this about the file it is
---about to open, which is not always the one on screen.
---@param entry table
---@return integer
function M.entry_conflicts(entry) return entry_conflicts(entry) end

---Conflicted files still holding markers, counted across the whole changeset
---rather than the panes on screen: a file the review has not opened yet is
---every bit as unresolved, and `git merge --continue` counts it too.
---@param view table?
---@return integer
function M.unresolved(view)
  view = view or current_view()
  if not view then return 0 end
  return (remaining(view))
end

---Say what a resolution was, on the resolution itself. A region that has been
---resolved has no markers left, so without this there is nothing to go back to
---and nothing to check: the file just looks like a file.
---@param bufnr integer
---@param first integer 1-indexed first line of the resolution
---@param count integer lines it produced; zero means the region was dropped
---@param took DiffHudTook
function M.mark(bufnr, first, count, took)
  if not (usable(bufnr) and TOOK[took]) then return end
  local last = api.nvim_buf_line_count(bufnr)
  local row = math.max(0, math.min(first - 1, last - 1))
  -- Dropping what is left of a region you built line by line is the end of
  -- that build, not a decision to say twice.
  if took == "dropped" and row > 0 then
    local above = { row - 1, 0 }
    if #api.nvim_buf_get_extmarks(bufnr, MARK_NS, above, { row - 1, -1 }, { overlap = true }) > 0 then return end
  end
  api.nvim_buf_set_extmark(bufnr, MARK_NS, row, 0, {
    end_row = math.max(row, math.min(row + math.max(count, 1) - 1, last - 1)),
    number_hl_group = "DiffHudMark",
    virt_text = { { "  " .. TOOK[took], "DiffHudMark" } },
    virt_text_pos = "eol",
  })
end

---The resolutions in a file, in line order, for walking back over them. The
---lines move with your later edits because the marks do.
---@param bufnr integer?
---@return { lnum: integer, took: string }[]
function M.resolutions(bufnr)
  if not usable(bufnr) then return {} end
  local list = {}
  for _, mark in ipairs(api.nvim_buf_get_extmarks(bufnr, MARK_NS, 0, -1, { details = true })) do
    local virt = mark[4] and mark[4].virt_text
    local took = virt and virt[1] and virt[1][1] or ""
    list[#list + 1] = { lnum = mark[2] + 1, took = vim.trim(took) }
  end
  table.sort(list, function(a, b) return a.lnum < b.lnum end)
  return list
end

---`<Tab>` in a merge: the next file that still has conflicts in it, rather
---than the next file in the changeset.
---@param view table?
---@return boolean whether it moved
function M.next_conflict_file(view)
  view = view or current_view()
  local files = view and view.files and view.files.conflicting or {}
  if #files == 0 then return false end

  -- From here forwards, wrapping: "next" has to mean next, even though the
  -- file that still needs work may be one you have already walked past.
  local at = 0
  for index, entry in ipairs(files) do
    if entry == view.cur_entry then at = index end
  end
  for step = 1, #files do
    local entry = files[(at + step - 1) % #files + 1]
    if entry ~= view.cur_entry and entry_conflicts(entry) > 0 then
      notify(("Moving to %s -- %d left with conflicts"):format(entry.path, remaining(view)))
      return (pcall(function() view:set_file(entry, true) end))
    end
  end
  return false
end

---What kind of pane the review is showing here, so anything that needs to know
---whether this is a merge does not have to work it out again.
---@return DiffHudKind?
function M.current_kind()
  local pane = panes[api.nvim_get_current_win()]
  if pane then return pane.kind end
  for _, winid in ipairs(api.nvim_tabpage_list_wins(0)) do
    if panes[winid] then return panes[winid].kind end
  end
end

---A pane showing a file that exists on only one side has nothing to diff
---against, so the revert keys have to say that instead of failing.
---@return "new"|"gone"|nil
function M.lone_kind()
  local pane = panes[api.nvim_get_current_win()]
  if pane and (pane.kind == "new" or pane.kind == "gone") then return pane.kind end
end

---A closing view takes its windows with it; a second review in another tab
---keeps its own.
function M.closed()
  vim.schedule(function()
    forget_closed_windows()
    memos = {}
  end)
end

set_highlights()
api.nvim_create_autocmd("ColorScheme", {
  group = api.nvim_create_augroup("diff_hud_highlights", { clear = true }),
  desc = "Rebuild the diff review winbar colors",
  callback = set_highlights,
})

return M
