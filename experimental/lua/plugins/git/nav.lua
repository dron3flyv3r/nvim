local M = {}

local api = vim.api

-- Diffview opens with the cursor in the file panel, where an unbound `n` falls
-- through to Vim's own search and reports E35 or jumps to a match from the shada
-- file. Panel navigation moves into the diff first.
local function focus_diff()
  local ok, lib = pcall(require, "diffview.lib")
  if not ok then return end
  local found, view = pcall(lib.get_current_view)
  local layout = found and view and view.cur_layout or nil
  local main = layout and layout.get_main_win and layout:get_main_win()
  local winid = main and main.id
  if winid and api.nvim_win_is_valid(winid) then api.nvim_set_current_win(winid) end
end

---@param reverse boolean
local function goto_edge_change(reverse)
  vim.cmd("normal! " .. (reverse and "G" or "gg"))
  -- A file shown in a single pane is entirely new or entirely gone: its edge is
  -- the edge of the file, and `diff_hlID` has nothing to say about it.
  if not vim.wo.diff then return end
  local lnum = api.nvim_win_get_cursor(0)[1]
  if vim.fn.diff_hlID(lnum, 1) == 0 then pcall(vim.cmd, "normal! " .. (reverse and "[c" or "]c")) end
end

---@param reverse boolean
---@return fun()
function M.change(reverse)
  return function()
    local before = api.nvim_win_get_cursor(0)[1]
    local ok = pcall(vim.cmd, "normal! " .. (reverse and "[c" or "]c"))
    if ok and api.nvim_win_get_cursor(0)[1] ~= before then return end

    local actions = require "diffview.actions"
    if reverse then
      actions.select_prev_entry()
    else
      actions.select_next_entry()
    end

    -- Loading an entry is asynchronous: the buffers, the diff and the window
    -- layout are not in place on the next tick. This waits for the window to be
    -- showing the file rather than guessing a delay.
    local tries = 0
    local finished = false
    local timer = assert(vim.uv.new_timer())
    timer:start(
      20,
      20,
      vim.schedule_wrap(function()
        -- Stopping the timer does not cancel callbacks already scheduled while
        -- Diffview was rebuilding the panes. Only the first may jump.
        if finished then return end
        tries = tries + 1
        local ready = vim.wo.diff or require("plugins.git.hud").lone_kind() ~= nil
        if ready or tries > 25 then
          finished = true
          timer:stop()
          timer:close()
          if ready then goto_edge_change(reverse) end
        end
      end)
    )
  end
end

-- `n` from the file panel: into the diff first, then whatever "next" means there
-- -- the next conflict during a merge, the next change otherwise.
---@param reverse boolean
---@return fun()
function M.panel(reverse)
  return function()
    focus_diff()
    local kind = require("plugins.git.hud").current_kind()
    if kind == "ours" or kind == "result" or kind == "theirs" then
      return require("plugins.git.conflicts").nav_conflict(reverse)()
    end
    M.change(reverse)()
  end
end

return M
