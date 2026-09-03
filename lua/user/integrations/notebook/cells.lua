local M = {}

local CELL = "^%s*#%s*%%%%"
local CELL_PROSE = "^%s*#%s*%%%%%s*%[markdown%]"
local MARKER = "# %%"

---@param bufnr? integer
---@return integer[]
function M.starts(bufnr)
  bufnr = bufnr or 0
  local starts = {}
  for i, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if line:match(CELL) then starts[#starts + 1] = i end
  end
  return starts
end

---@param lnum? integer defaults to the cursor line
---@param bufnr? integer
---@return integer first, integer last
function M.bounds(lnum, bufnr)
  bufnr = bufnr or 0
  lnum = lnum or vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  local first = 1
  for i = lnum, 1, -1 do
    if lines[i] and lines[i]:match(CELL) then
      first = i
      break
    end
  end

  local last = #lines
  for i = lnum + 1, #lines do
    if lines[i]:match(CELL) then
      last = i - 1
      break
    end
  end

  return first, last
end

---@param dir 1|-1
function M.goto_cell(dir)
  local starts = M.starts()
  if vim.tbl_isempty(starts) then
    vim.notify("No `# %%` cells in this file -- <Leader>ra can add one", vim.log.levels.INFO, { title = "Notebook" })
    return
  end

  local cur = vim.api.nvim_win_get_cursor(0)[1]
  local target
  if dir > 0 then
    for _, start in ipairs(starts) do
      if start > cur then
        target = start
        break
      end
    end
  else
    local first = M.bounds(cur)
    if first < cur then
      target = first
    else
      for i = #starts, 1, -1 do
        if starts[i] < cur then
          target = starts[i]
          break
        end
      end
    end
  end
  if not target then return end

  vim.cmd "normal! m'"
  vim.api.nvim_win_set_cursor(0, { target, 0 })
end

---@param below boolean
function M.insert(below)
  local first, last = M.bounds()
  local at = below and last or first - 1
  vim.api.nvim_buf_set_lines(0, at, at, false, { "", MARKER, "" })
  vim.api.nvim_win_set_cursor(0, { at + 3, 0 })
  vim.cmd.startinsert()
end

---@param lnum integer
---@param bufnr? integer
---@return boolean
function M.is_prose(lnum, bufnr)
  local line = vim.api.nvim_buf_get_lines(bufnr or 0, lnum - 1, lnum, false)[1]
  return line ~= nil and line:match(CELL_PROSE) ~= nil
end

return M
