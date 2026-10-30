local M = {}

---@param win integer
---@return boolean
local function shows_file(win)
  if win == 0 or not vim.api.nvim_win_is_valid(win) then return false end
  if vim.api.nvim_win_get_config(win).relative ~= "" or vim.w[win].core_pane then return false end
  return vim.bo[vim.api.nvim_win_get_buf(win)].buftype == ""
end

---@return integer
function M.window()
  local previous = vim.fn.win_getid(vim.fn.winnr "#")
  if shows_file(vim.api.nvim_get_current_win()) then return vim.api.nvim_get_current_win() end
  if shows_file(previous) then return previous end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if shows_file(win) then return win end
  end
  local scratch = vim.api.nvim_create_buf(false, true)
  vim.bo[scratch].bufhidden = "wipe"
  local strip = require("core.pane").wins()[1]
  if strip then return vim.api.nvim_open_win(scratch, false, { split = "above", win = strip }) end
  return vim.api.nvim_open_win(scratch, false, { split = "left", win = -1 })
end

---@param path string
---@param pos? { line: integer, col?: integer }
function M.file(path, pos)
  vim.api.nvim_set_current_win(M.window())
  vim.cmd.drop(vim.fn.fnameescape(path))
  if not pos then return end
  local row = math.min(math.max(1, pos.line), vim.api.nvim_buf_line_count(0))
  vim.api.nvim_win_set_cursor(0, { row, math.max(0, pos.col or 0) })
  vim.cmd "normal! zz"
end

return M
