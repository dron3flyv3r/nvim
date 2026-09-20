local M = {}

local HEIGHT = 15

local WIN_OPTS = {
  number = false,
  relativenumber = false,
  signcolumn = "no",
  foldcolumn = "0",
  statuscolumn = "",
  wrap = true,
  sidescrolloff = 0,
  cursorline = false,
  cursorcolumn = false,
  list = false,
  spell = false,
  winfixheight = true,
}

---@class core.pane.Occupant
---@field name string
---@field bufnr integer
---@field close? fun()

---@type table<string, core.pane.Occupant>
local occupants = {}

---@return integer|nil
function M.get_win()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(win).relative == "" and vim.w[win].core_pane then return win end
  end
end

---@return string|nil
function M.current()
  local win = M.get_win()
  if not win then return nil end
  local bufnr = vim.api.nvim_win_get_buf(win)
  for name, occupant in pairs(occupants) do
    if occupant.bufnr == bufnr then return name end
  end
end

---@return string[]
function M.names()
  local names = {}
  for name, occupant in pairs(occupants) do
    if vim.api.nvim_buf_is_valid(occupant.bufnr) then names[#names + 1] = name end
  end
  table.sort(names)
  return names
end

---@return integer
function M.window()
  local win = M.get_win()
  if win then return win end

  local return_to = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_config(0).relative ~= "" then
    for _, candidate in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_config(candidate).relative == "" then
        vim.api.nvim_set_current_win(candidate)
        break
      end
    end
  end

  -- botright, so the strip spans the full width regardless of which window the
  -- cursor was in and whatever is docked down the side of the tab.
  vim.cmd(("noautocmd botright %dsplit"):format(HEIGHT))
  win = vim.api.nvim_get_current_win()
  vim.w[win].core_pane = true
  if vim.api.nvim_win_is_valid(return_to) then vim.api.nvim_set_current_win(return_to) end
  return win
end

---@param win integer
local function scroll_to_end(win)
  local bufnr = vim.api.nvim_win_get_buf(win)
  local count = vim.api.nvim_buf_line_count(bufnr)
  pcall(vim.api.nvim_win_set_cursor, win, { count, 0 })
end

---@param step integer
local function cycle(step)
  local names = M.names()
  if #names < 2 then return end
  local current = M.current()
  local index = 1
  for i, name in ipairs(names) do
    if name == current then index = i end
  end
  M.show(occupants[names[(index - 1 + step) % #names + 1]], { enter = true })
end

---@param occupant core.pane.Occupant
local function bind(occupant)
  local buf = occupant.bufnr
  -- Normal mode only: in terminal mode these letters are ordinary input to an
  -- interactive process.
  vim.keymap.set("n", "h", M.hide, { buffer = buf, desc = "Hide the pane" })
  vim.keymap.set("n", "q", function()
    if occupant.close then return occupant.close() end
    M.hide()
  end, { buffer = buf, desc = "Close this pane occupant" })
  vim.keymap.set("n", "<Tab>", function() cycle(1) end, { buffer = buf, desc = "Next pane occupant" })
  vim.keymap.set("n", "<S-Tab>", function() cycle(-1) end, { buffer = buf, desc = "Previous pane occupant" })
end

---@param occupant core.pane.Occupant
---@param opts? { enter?: boolean, insert?: boolean }
---@return integer|nil
function M.show(occupant, opts)
  opts = opts or {}
  if not vim.api.nvim_buf_is_valid(occupant.bufnr) then return nil end
  occupants[occupant.name] = occupant

  local win = M.window()
  if vim.api.nvim_win_get_buf(win) ~= occupant.bufnr then vim.api.nvim_win_set_buf(win, occupant.bufnr) end
  for opt, value in pairs(WIN_OPTS) do
    vim.api.nvim_set_option_value(opt, value, { scope = "local", win = win })
  end

  scroll_to_end(win)
  bind(occupant)

  if opts.enter then
    vim.api.nvim_set_current_win(win)
    local buftype = vim.bo[occupant.bufnr].buftype
    if opts.insert and (buftype == "terminal" or buftype == "prompt") then vim.cmd.startinsert() end
  end
  return win
end

---@param name string
---@param opts? { enter?: boolean, insert?: boolean }
---@return integer|nil
function M.focus(name, opts)
  local occupant = occupants[name]
  if not occupant or not vim.api.nvim_buf_is_valid(occupant.bufnr) then return nil end
  return M.show(occupant, opts)
end

function M.hide()
  local win = M.get_win()
  if win then vim.api.nvim_win_close(win, false) end
end

---@param name string
function M.release(name)
  local occupant = occupants[name]
  if not occupant then return end
  local showing = M.current() == name
  occupants[name] = nil
  if not showing then return end

  local names = M.names()
  if #names == 0 then return M.hide() end
  M.show(occupants[names[1]])
end

---@param bufnr integer
function M.refresh(bufnr)
  local win = M.get_win()
  if win and vim.api.nvim_win_get_buf(win) == bufnr then scroll_to_end(win) end
end

return M
