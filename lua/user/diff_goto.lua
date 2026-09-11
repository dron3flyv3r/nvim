--- Leaving a review at the file you are reading. Diffview's own `gf` opens the
--- file and leaves the review standing behind it, which walks straight past the
--- hold `diff_review` has on that exact buffer: `readonly` still set, autosave
--- still off, pending reverts still only in memory. These settle the review
--- first -- the same Save/Discard/Cancel prompt `q` asks -- and only then open.
local M = {}

local api = vim.api

---@param msg string
---@param level? integer
local function notify(msg, level) require("astrocore").notify(msg, level or vim.log.levels.WARN, { title = "Git" }) end

---@return table?
local function current_view()
  local ok, lib = pcall(require, "diffview.lib")
  if not ok then return nil end
  local found, view = pcall(lib.get_current_view)
  return found and view or nil
end

---@class DiffGotoTarget
---@field path string
---@field line integer
---@field tab integer? the tabpage to open in

---Everything the jump needs, read while the review is still on screen: the
---entry is destroyed with the view, and so is the window the line comes from.
---@return DiffGotoTarget?
local function target()
  local view = current_view()
  if not (view and type(view.infer_cur_file) == "function") then return notify "Not in a review" end

  local entry = view:infer_cur_file()
  if not entry then return notify "No file under the cursor" end
  local path = entry.absolute_path
  if not path or path == "" then return notify "That entry is not a file on disk" end
  if vim.fn.filereadable(path) == 0 then return notify "This file is deleted -- there is nothing on disk to open" end

  -- A merge writes nothing while markers are left, so closing here would leave
  -- the resolution built in the buffer behind and open the copy from disk.
  if view.merge_ctx and require("user.diff_hud").entry_conflicts(entry) > 0 then
    return notify "This file still has conflicts -- resolve them first, or q to leave the whole merge"
  end

  -- Only the file on screen has a cursor to carry over. The layout's main
  -- window is the working side, which Diffview keeps aligned with the other
  -- pane, so the line is the one you were reading whichever pane you stood in.
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

---The buffer the review was holding is the buffer to show. Reaching the file by
---name instead would re-read it from disk and throw away whatever Save or
---Discard just settled in that buffer.
---@param path string
local function show(path)
  local buf = vim.fn.bufnr("^" .. path .. "$")
  if buf ~= -1 and api.nvim_buf_is_loaded(buf) then
    api.nvim_win_set_buf(0, buf)
  else
    vim.cmd("edit " .. vim.fn.fnameescape(path))
  end
end

---@param t DiffGotoTarget
---@param how "edit"|"split"|"tab"
local function open(t, how)
  if t.tab and api.nvim_tabpage_is_valid(t.tab) then api.nvim_set_current_tabpage(t.tab) end

  if how == "split" then
    vim.cmd.split()
  elseif how == "tab" then
    vim.cmd.tabnew()
  end

  -- `:tabnew` opens on an empty buffer, and so does Diffview when the review
  -- had the only tab. Either is left listed unless it is cleared away here.
  local before = api.nvim_get_current_buf()
  local spare = api.nvim_buf_get_name(before) == "" and not vim.bo[before].modified

  show(t.path)
  if spare and before ~= api.nvim_get_current_buf() then pcall(api.nvim_buf_delete, before, { force = true }) end

  api.nvim_win_set_cursor(0, { math.min(t.line, api.nvim_buf_line_count(0)), 0 })
  pcall(vim.cmd, "normal! zv")
end

---`gf` and its split and tab variants.
---@param how "edit"|"split"|"tab"
function M.leave(how)
  local t = target()
  if not t then return end

  -- The prompt decides what happens to the very buffer about to be opened, so
  -- it has to be answered first. Cancel leaves the review standing and the
  -- cursor where it was.
  local closed, finishing = require("user.diff_review").close()
  if not closed then return end
  -- "Save and finish" is already taking this tab for the staged review, and
  -- that is the more specific thing to have asked for.
  if finishing then return end

  open(t, how)
end

return M
