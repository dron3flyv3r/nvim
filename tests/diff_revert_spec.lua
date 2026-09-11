-- Run with: nvim --headless -u NONE -l tests/diff_revert_spec.lua
local original_vim = vim
local original_module = package.loaded["user.diff_revert"]
local original_astrocore = package.loaded["astrocore"]
local original_hud = package.loaded["user.diff_hud"]
local original_review = package.loaded["user.diff_review"]

local WORKTREE, OTHER = 1, 2
local NAMES = { [WORKTREE] = "/tmp/f.lua", [OTHER] = "diffview:///f.lua" }

---A buffer world just real enough for the module: two panes, line edits that
---move extmarks the way Neovim's do, and a record of what was said.
local function world(old, new, old_pane_first)
  local state = {
    lines = { [WORKTREE] = vim.deepcopy(new), [OTHER] = vim.deepcopy(old) },
    marks = {},
    said = {},
    cursor = nil,
    joins = 0,
    focus = WORKTREE,
    selection = { 1, 1 },
    next_mark = 0,
  }

  local api = {
    nvim_create_namespace = function() return 1 end,
    nvim_tabpage_list_wins = function() return old_pane_first and { 11, 10 } or { 10, 11 } end,
    nvim_win_get_buf = function(win) return win == 10 and WORKTREE or OTHER end,
    nvim_buf_get_name = function(buf) return NAMES[buf] end,
    nvim_get_current_buf = function() return state.focus end,
    nvim_get_current_win = function() return state.focus == WORKTREE and 10 or 11 end,
    nvim_buf_get_lines = function(buf) return vim.deepcopy(state.lines[buf]) end,
    nvim_buf_line_count = function(buf) return #state.lines[buf] end,
    nvim_buf_call = function(_, fn) fn() end,
    nvim_win_set_cursor = function(_, pos) state.cursor = pos end,
    nvim_buf_set_lines = function(buf, first, last, _, replacement)
      local kept = {}
      for i = 1, first do
        kept[#kept + 1] = state.lines[buf][i]
      end
      for _, line in ipairs(replacement) do
        kept[#kept + 1] = line
      end
      for i = last + 1, #state.lines[buf] do
        kept[#kept + 1] = state.lines[buf][i]
      end
      state.lines[buf] = kept
      local delta = #replacement - (last - first)
      for id, mark in pairs(state.marks) do
        if mark >= last then state.marks[id] = mark + delta end
      end
    end,
    nvim_buf_set_extmark = function(_, _, row)
      state.next_mark = state.next_mark + 1
      state.marks[state.next_mark] = row
      return state.next_mark
    end,
    nvim_buf_get_extmark_by_id = function(_, _, id) return { state.marks[id], 0 } end,
    nvim_buf_del_extmark = function(_, _, id) state.marks[id] = nil end,
  }

  local fake = setmetatable({
    api = api,
    bo = setmetatable(
      {},
      { __index = function(_, buf) return { buftype = buf == WORKTREE and "" or "nofile", modifiable = true } end }
    ),
    wo = setmetatable({ diff = true }, { __index = function() return { diff = true } end }),
    fn = setmetatable({
      line = function(what) return what == "v" and state.selection[1] or state.selection[2] end,
    }, { __index = original_vim.fn }),
    cmd = setmetatable({}, {
      __call = function(_, command)
        if command == "undojoin" then state.joins = state.joins + 1 end
      end,
      __index = function()
        return function() end
      end,
    }),
  }, { __index = original_vim })

  package.loaded["astrocore"] = { notify = function(msg) state.said[#state.said + 1] = msg end }
  package.loaded["user.diff_hud"] = { lone_kind = function() return nil end }
  package.loaded["user.diff_review"] = { track = function() return true end, writable = function() return true end }
  vim = fake
  package.loaded["user.diff_revert"] = nil
  return state, dofile "lua/user/diff_revert.lua"
end

local ok, err = pcall(function()
  local FORMATTED = {
    "local function a()",
    "    return 1",
    "end",
    "",
    "local function b()",
    "  return 22",
    "end",
    "",
    "local function c()",
    "    return 3",
    "end",
  }
  local ORIGINAL = {
    "local function a()",
    "  return 1",
    "end",
    "",
    "local function b()",
    "  return 2",
    "end",
    "",
    "local function c()",
    "  return 3",
    "end",
  }
  -- Everything unformatted, with only the edit on line 6 surviving.
  local WANTED = vim.deepcopy(ORIGINAL)
  WANTED[6] = "  return 22"

  local state, M = world(ORIGINAL, FORMATTED)
  state.selection = { 6, 6 }
  M.keep_selection()
  assert(vim.deep_equal(state.lines[WORKTREE], WANTED), "keep: the selected hunk survives, the rest reverts")
  assert(state.joins == 1, "keep: two reverted hunks are one undo block")
  assert(state.said[1]:find "Reverted 2 changes, kept 1", "keep: says what it did -- " .. state.said[1])

  state, M = world(ORIGINAL, FORMATTED)
  M.unformat()
  assert(vim.deep_equal(state.lines[WORKTREE], WANTED), "unformat: whitespace-only hunks go, the real edit stays")
  assert(state.said[1]:find "Reverted 2 whitespace%-only changes, 1 left", "unformat: says what it did")

  -- A selection that missed every change is a whole-file revert by accident.
  state, M = world(ORIGINAL, FORMATTED)
  state.selection = { 4, 4 }
  M.keep_selection()
  assert(vim.deep_equal(state.lines[WORKTREE], FORMATTED), "keep: a selection touching nothing changes nothing")
  assert(state.said[1]:find "R reverts the whole file", "keep: points at R instead")

  state, M = world(ORIGINAL, FORMATTED)
  state.selection = { 2, 10 }
  M.keep_selection()
  assert(vim.deep_equal(state.lines[WORKTREE], FORMATTED), "keep: a selection covering everything changes nothing")
  assert(state.said[1]:find "covers every change", "keep: says the selection covers everything")

  -- A hunk with nothing on the new side is an insertion point, not a line, and
  -- restoring it shifts the lines the cursor was anchored to.
  state, M = world({ "a", "b", "c", "d" }, { "a", "c", "D" })
  state.selection = { 3, 3 }
  M.keep_selection()
  assert(
    vim.deep_equal(state.lines[WORKTREE], { "a", "b", "c", "D" }),
    "keep: a deleted line outside the selection comes back"
  )
  assert(state.cursor and state.cursor[1] == 4, "keep: the cursor follows the kept line down")

  state, M = world(ORIGINAL, FORMATTED)
  state.focus = OTHER
  M.keep_selection()
  assert(vim.deep_equal(state.lines[WORKTREE], FORMATTED), "keep: refuses to act from the old pane")
  assert(state.said[1]:find "this pane is the old one", "keep: says which pane to select in")

  state, M = world(ORIGINAL, ORIGINAL)
  M.unformat()
  assert(state.said[1]:find "No changes in this file", "unformat: an unchanged file says so")

  state, M = world({ "a", "b" }, { "a", "B" })
  M.unformat()
  assert(vim.deep_equal(state.lines[WORKTREE], { "a", "B" }), "unformat: a real change is left alone")
  assert(state.said[1]:find "every change in this file alters the text", "unformat: says there was nothing to undo")

  -- Rewrapping across lines is whitespace; running two words together is not.
  state, M = world({ "foo(", "  bar", ")" }, { "foo( bar )" })
  M.unformat()
  assert(vim.deep_equal(state.lines[WORKTREE], { "foo(", "  bar", ")" }), "unformat: a rewrap counts as whitespace")

  state, M = world({ "foo bar" }, { "foobar" })
  M.unformat()
  assert(vim.deep_equal(state.lines[WORKTREE], { "foobar" }), "unformat: joining two words is not whitespace")

  -- Diffview lists the old pane before the working one, which is the order that
  -- caught the two panes reading as a crowded layout.
  state, M = world(ORIGINAL, FORMATTED, true)
  M.unformat()
  assert(vim.deep_equal(state.lines[WORKTREE], WANTED), "unformat: works whichever pane the tab lists first")
end)

vim = original_vim
package.loaded["user.diff_revert"] = original_module
package.loaded["astrocore"] = original_astrocore
package.loaded["user.diff_hud"] = original_hud
package.loaded["user.diff_review"] = original_review
assert(ok, err)
print "Diff revert regression checks passed"
