local M = {}

local api = vim.api

---@param message string
---@param level? integer
local function say(message, level) vim.notify(message, level or vim.log.levels.WARN, { title = "Git" }) end

---@return table?
local function current_view()
  local ok, lib = pcall(require, "diffview.lib")
  if not ok then return nil end
  local found, view = pcall(lib.get_current_view)
  return found and view or nil
end

---@class git.goto.Target
---@field path string
---@field line integer
---@field tab integer?

-- Everything the jump needs, read while the review is still on screen: the entry
-- is destroyed with the view, and so is the window the line comes from.
---@return git.goto.Target?
local function target()
  local view = current_view()
  if not (view and type(view.infer_cur_file) == "function") then return say "Not in a review" end

  local entry = view:infer_cur_file()
  if not entry then return say "No file under the cursor" end
  local path = entry.absolute_path
  if not path or path == "" then return say "That entry is not a file on disk" end
  if vim.fn.filereadable(path) == 0 then return say "This file is deleted -- there is nothing on disk to open" end

  -- A merge writes nothing while markers are left, so closing here would leave
  -- the resolution built in the buffer behind and open the copy from disk.
  if view.merge_ctx and require("plugins.git.hud").entry_conflicts(entry) > 0 then
    return say "This file still has conflicts -- resolve them first, or q to leave the whole merge"
  end

  -- Only the file on screen has a cursor to carry over. The layout's main window
  -- is the working side, which Diffview keeps aligned with the other pane, so
  -- the line is the one you were reading whichever pane you stood in.
  local line = 1
  if entry == view.cur_entry then
    local layout = view.cur_layout
    local main = layout and layout.get_main_win and layout:get_main_win()
    local win = main and main.id
    if win and api.nvim_win_is_valid(win) then line = api.nvim_win_get_cursor(win)[1] end
  end

  local ok, lib = pcall(require, "diffview.lib")
  return { path = path, line = line, tab = ok and lib.get_prev_non_view_tabpage() or nil }
end

-- The buffer the review was holding is the buffer to show. Reaching the file by
-- name instead would re-read it from disk and throw away whatever Save or
-- Discard just settled there.
---@param path string
local function show(path)
  local buf = vim.fn.bufnr("^" .. path .. "$")
  if buf ~= -1 and api.nvim_buf_is_loaded(buf) then
    api.nvim_win_set_buf(0, buf)
  else
    vim.cmd("edit " .. vim.fn.fnameescape(path))
  end
end

---@param t git.goto.Target
---@param how "edit"|"split"|"tab"
local function open(t, how)
  if t.tab and api.nvim_tabpage_is_valid(t.tab) then api.nvim_set_current_tabpage(t.tab) end

  if how == "split" then
    vim.cmd.split()
  elseif how == "tab" then
    vim.cmd.tabnew()
  end

  -- `:tabnew` opens on an empty buffer, and so does Diffview when the review had
  -- the only tab. Either is left listed unless it is cleared away here.
  local before = api.nvim_get_current_buf()
  local spare = api.nvim_buf_get_name(before) == "" and not vim.bo[before].modified

  show(t.path)
  if spare and before ~= api.nvim_get_current_buf() then pcall(api.nvim_buf_delete, before, { force = true }) end

  api.nvim_win_set_cursor(0, { math.min(t.line, api.nvim_buf_line_count(0)), 0 })
  pcall(vim.cmd, "normal! zv")
end

-- Diffview's own `gf` opens the file and leaves the review standing behind it,
-- walking straight past the hold on that exact buffer. Its three keys are taken
-- over rather than left beside new ones, so the version that bypasses the
-- transaction cannot be reached by accident.
---@param how "edit"|"split"|"tab"
---@return fun()
function M.leave(how)
  return function()
    local t = target()
    if not t then return end

    -- The prompt decides what happens to the very buffer about to be opened, so
    -- it has to be answered first. Cancel leaves the review standing.
    local closed, finishing = require("plugins.git.review").close()
    if not closed then return end
    -- "Save and finish" is already taking this tab for the staged review, and
    -- that is the more specific thing to have asked for.
    if finishing then return end

    open(t, how)
  end
end

return M
