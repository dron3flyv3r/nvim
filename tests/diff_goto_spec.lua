-- Run with: nvim --headless -u NONE -l tests/diff_goto_spec.lua
local original_vim = vim
local original_module = package.loaded["user.diff_goto"]
local original_astrocore = package.loaded["astrocore"]
local original_hud = package.loaded["user.diff_hud"]
local original_review = package.loaded["user.diff_review"]
local original_lib = package.loaded["diffview.lib"]

local FILE_BUF, SPARE_BUF = 7, 8
local PATH = "/tmp/goto.lua"
local MAIN_WIN = 10

---A review just real enough for the module: one entry, a main window with a
---cursor in it, and a record of what was closed, opened and said.
---@param overrides table?
local function world(overrides)
  overrides = overrides or {}
  local entry = { absolute_path = overrides.path or PATH }
  local state = {
    said = {},
    closed = 0,
    tab = nil,
    shown = nil,
    edited = nil,
    cursor = nil,
    deleted = {},
    split = 0,
    tabnew = 0,
    lines = 40,
    buffers = { [FILE_BUF] = PATH },
  }

  local view = {
    merge_ctx = overrides.merge and {} or nil,
    cur_entry = overrides.other_entry and {} or entry,
    cur_layout = { get_main_win = function() return { id = MAIN_WIN } end },
    infer_cur_file = function()
      if overrides.no_entry then return nil end
      return entry
    end,
  }

  local current = FILE_BUF
  local api = {
    nvim_win_is_valid = function() return true end,
    nvim_tabpage_is_valid = function() return true end,
    nvim_set_current_tabpage = function(tab) state.tab = tab end,
    nvim_win_get_cursor = function() return { 23, 0 } end,
    nvim_win_set_cursor = function(_, pos) state.cursor = pos end,
    nvim_win_set_buf = function(_, buf)
      state.shown = buf
      current = buf
    end,
    nvim_buf_is_loaded = function(buf) return state.buffers[buf] ~= nil end,
    nvim_get_current_buf = function() return current end,
    nvim_buf_get_name = function(buf) return state.buffers[buf] or "" end,
    nvim_buf_line_count = function() return state.lines end,
    nvim_buf_delete = function(buf) state.deleted[#state.deleted + 1] = buf end,
  }

  local fake = setmetatable({
    api = api,
    bo = setmetatable({}, { __index = function() return { modified = false } end }),
    fn = setmetatable({
      filereadable = function() return overrides.missing and 0 or 1 end,
      bufnr = function() return overrides.unloaded and -1 or FILE_BUF end,
      fnameescape = function(name) return name end,
    }, { __index = original_vim.fn }),
    cmd = setmetatable({
      split = function() state.split = state.split + 1 end,
      tabnew = function()
        state.tabnew = state.tabnew + 1
        current = SPARE_BUF
      end,
    }, {
      __call = function(_, command)
        local name = command:match "^edit (.+)$"
        if name then
          state.edited = name
          current = FILE_BUF
        end
      end,
    }),
  }, { __index = original_vim })

  package.loaded["astrocore"] = { notify = function(msg) state.said[#state.said + 1] = msg end }
  package.loaded["user.diff_hud"] = { entry_conflicts = function() return overrides.conflicts or 0 end }
  package.loaded["user.diff_review"] = {
    close = function()
      state.closed = state.closed + 1
      if overrides.cancelled then return false end
      return true, overrides.finishing or nil
    end,
  }
  package.loaded["diffview.lib"] = {
    get_current_view = function()
      if overrides.no_view then return nil end
      return view
    end,
    get_prev_non_view_tabpage = function()
      if overrides.lone_tab then return nil end
      return 3
    end,
  }
  vim = fake
  package.loaded["user.diff_goto"] = nil
  return state, dofile "lua/user/diff_goto.lua"
end

local ok, err = pcall(function()
  local state, M = world()
  M.leave "edit"
  assert(state.closed == 1, "edit: the review is settled before anything opens")
  assert(state.tab == 3, "edit: it opens in the tab the review was launched from")
  assert(state.shown == FILE_BUF, "edit: the held buffer is reused rather than re-read from disk")
  assert(state.edited == nil, "edit: a loaded buffer is never :edit-ed")
  assert(state.cursor and state.cursor[1] == 23, "edit: the cursor lands on the line you were reading")

  -- Cancel at the prompt has to leave the review exactly as it was.
  state, M = world { cancelled = true }
  M.leave "edit"
  assert(state.closed == 1, "cancel: the prompt was still asked")
  assert(state.shown == nil and state.edited == nil, "cancel: nothing is opened")
  assert(state.tab == nil, "cancel: the tab is not changed either")

  -- "Save and finish" is already taking the tab for the staged review.
  state, M = world { finishing = true }
  M.leave "edit"
  assert(state.shown == nil and state.edited == nil, "finish: the staged pass keeps the tab")

  state, M = world { missing = true }
  M.leave "edit"
  assert(state.closed == 0, "deleted: the review is not closed")
  assert(state.said[1]:find "This file is deleted", "deleted: says there is nothing to open")

  state, M = world { merge = true, conflicts = 2 }
  M.leave "edit"
  assert(state.closed == 0, "conflicts: the merge is left standing")
  assert(state.said[1]:find "still has conflicts", "conflicts: says why -- " .. tostring(state.said[1]))

  -- A resolved file in a merge is an ordinary jump.
  state, M = world { merge = true, conflicts = 0 }
  M.leave "edit"
  assert(state.shown == FILE_BUF, "conflicts: a resolved file in a merge still opens")

  -- From the file panel the entry is not the one on screen, so its cursor
  -- belongs to a different file and the jump starts at the top instead.
  state, M = world { other_entry = true }
  M.leave "edit"
  assert(state.cursor and state.cursor[1] == 1, "panel: another file opens at the top")

  -- The line is clamped: the buffer settled by Discard can be shorter than the
  -- version that was on screen when the cursor was read.
  state, M = world()
  state.lines = 5
  M.leave "edit"
  assert(state.cursor and state.cursor[1] == 5, "clamp: a line past the end of the file is pulled back")

  state, M = world { unloaded = true }
  M.leave "edit"
  assert(state.edited == PATH, "unloaded: a file with no buffer is read from disk")

  state, M = world()
  M.leave "split"
  assert(state.split == 1 and state.shown == FILE_BUF, "split: opens in a new window")

  state, M = world { lone_tab = true }
  M.leave "tab"
  assert(state.tabnew == 1, "tab: opens a new tabpage")
  assert(state.tab == nil, "tab: there was no previous tab to return to")
  assert(state.deleted[1] == SPARE_BUF, "tab: the empty buffer :tabnew opened is cleared away")

  state, M = world { no_entry = true }
  M.leave "edit"
  assert(state.closed == 0, "no entry: nothing is closed")
  assert(state.said[1]:find "No file under the cursor", "no entry: says so")

  state, M = world { no_view = true }
  M.leave "edit"
  assert(state.said[1]:find "Not in a review", "no view: says so")
end)

vim = original_vim
package.loaded["user.diff_goto"] = original_module
package.loaded["astrocore"] = original_astrocore
package.loaded["user.diff_hud"] = original_hud
package.loaded["user.diff_review"] = original_review
package.loaded["diffview.lib"] = original_lib
assert(ok, err)
print "Diff goto regression checks passed"
