--- The reading half of the diff review. `diff_review.lua` decides what may be
--- written; this decides what the two panes look like: which side you are on,
--- where you are in the changeset, whole files instead of fold stubs, and a
--- single pane for a file that only exists on one side.
local M = {}

local api = vim.api

--- A high fold level rather than `foldenable = false`, so `zM` still collapses
--- to the changed regions -- the one thing the folded default is good for.
local OPEN_FOLDS = 99

--- How many event-loop turns to wait for Diffview to finish opening both panes
--- before giving up on hiding the empty one.
local READY_TRIES = 10

local WINBAR = "%{%v:lua.require'user.diff_hud'.winbar()%}"

---@alias DiffHudKind "before"|"yours"|"after"|"new"|"gone"|"empty"

--- `from` is the diff highlight the bar borrows its background from. The groups
--- are our own because Diffview remaps `DiffAdd` and friends per window, which
--- would repaint a label meant to say which window you are in.
local BARS = {
  before = { label = "BEFORE", from = "DiffDelete" },
  yours = { label = "YOURS", from = "DiffAdd" },
  after = { label = "AFTER", from = "DiffChange" },
  new = { label = "NEW FILE", from = "DiffAdd" },
  gone = { label = "DELETED", from = "DiffDelete" },
  empty = { label = "", from = "Normal" },
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

---@type table<integer, DiffHudPane>
local panes = {}

---@param name string
---@return table
local function hl(name) return api.nvim_get_hl(0, { name = name, link = false }) end

local function set_highlights()
  local normal, comment, warn = hl "Normal", hl "Comment", hl "WarningMsg"
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

---@param view table
---@param symbol string
---@return DiffHudKind
local function kind_of(view, symbol)
  local layout = view.cur_layout
  local window = layout and layout[symbol]
  local types = rev_types()
  local file = window and window.file
  if file and types and file.rev and file.rev.type == types.LOCAL and not file.nulled then return "yours" end
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

---@type { key: string?, list: integer[][] }
local hunks = { key = nil, list = {} }

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

  local key = ("%d:%d:%d:%d"):format(a, vim.b[a].changedtick, b, vim.b[b].changedtick)
  if hunks.key == key then return hunks.list end

  local ok, list = pcall(vim.diff, text(a), text(b), {
    result_type = "indices",
    algorithm = "histogram",
    indent_heuristic = true,
    linematch = 60,
  })
  hunks.key, hunks.list = key, (ok and type(list) == "table") and list or {}
  return hunks.list
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
  elseif pane.kind == "before" then
    -- The left side of a file history is a commit facing another commit, so
    -- nothing there is anyone's pending deletion.
    keep = { pane.rev, stats_label(pane) }
    extra = { pane.live and "lines you deleted still exist here" or "the version this commit changed" }
  else
    local change, changes = change_position(pane)
    keep = { pane.position, change and ("change %d/%d"):format(change, changes) or "no changes left" }
    if pane.kind == "after" then keep[#keep + 1] = pane.rev end
    extra = { escape(pane.path) }
  end

  local out = { ("%%#%s# %s"):format(group, bar.label ~= "" and bar.label .. " " or "") }
  if pane.kind == "yours" and usable(pane.bufnr) and vim.bo[pane.bufnr].modified then
    -- Before `%<`, so the one thing a narrow pane must not hide is the fact
    -- that this buffer is holding edits nothing has written yet.
    out[#out + 1] = ("%%#%sAlert# PENDING -- q to save or discard "):format(group)
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
  panes[winid] = {
    kind = kind_of(view, ctx.symbol),
    symbol = ctx.symbol,
    rev = rev_label(window and window.file),
    path = entry and entry.path or vim.fn.fnamemodify(api.nvim_buf_get_name(bufnr), ":~:."),
    position = file_position(view),
    live = kind_of(view, "b") == "yours",
    bufnr = bufnr,
    a_buf = layout and layout.a and layout.a.file and layout.a.file.bufnr or nil,
    b_buf = layout and layout.b and layout.b.file and layout.b.file.bufnr or nil,
  }
  vim.wo[winid].winbar = WINBAR
  vim.wo[winid].foldlevel = OPEN_FOLDS

  -- "b" is the last pane Diffview opens, so by now both files are known and
  -- one scheduled check is enough for the whole file entry.
  if ctx.symbol == "b" and ctx.layout_name:find "^diff2" then vim.schedule(function() hide_empty_side(view, 1) end) end
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
    hunks = { key = nil, list = {} }
  end)
end

set_highlights()
api.nvim_create_autocmd("ColorScheme", {
  group = api.nvim_create_augroup("diff_hud_highlights", { clear = true }),
  desc = "Rebuild the diff review winbar colors",
  callback = set_highlights,
})

return M
