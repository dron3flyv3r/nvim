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
---@field split? fun(win: integer) what a split of this occupant's window shows instead of a second copy
---@field title? fun(): string the window's winbar

---@type table<string, core.pane.Occupant>
local occupants = {}
local splitting = false

local WINBAR = "%!v:lua.require'core.pane'.winbar()"

---@param win integer
---@return boolean
local function is_pane(win)
  return vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_config(win).relative == "" and vim.w[win].core_pane == true
end

---@return integer[] windows of the strip in the current tab, left to right
function M.wins()
  local wins = vim.tbl_filter(is_pane, vim.api.nvim_tabpage_list_wins(0))
  table.sort(wins, function(a, b)
    local pa, pb = vim.api.nvim_win_get_position(a), vim.api.nvim_win_get_position(b)
    return pa[1] < pb[1] or (pa[1] == pb[1] and pa[2] < pb[2])
  end)
  return wins
end

---@return integer|nil
function M.get_win()
  local current = vim.api.nvim_get_current_win()
  if is_pane(current) then return current end
  return M.wins()[1]
end

---@param bufnr integer
---@return string|nil
local function name_of(bufnr)
  for name, occupant in pairs(occupants) do
    if occupant.bufnr == bufnr then return name end
  end
end

---@return string|nil
function M.current()
  local win = M.get_win()
  if not win then return nil end
  return name_of(vim.api.nvim_win_get_buf(win))
end

---@param bufnr integer
---@param except? integer
---@return integer|nil
local function shown_in(bufnr, except)
  for _, win in ipairs(M.wins()) do
    if win ~= except and vim.api.nvim_win_get_buf(win) == bufnr then return win end
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

local bind

---@param win integer
---@param occupant core.pane.Occupant
local function place(win, occupant)
  if vim.api.nvim_win_get_buf(win) ~= occupant.bufnr then vim.api.nvim_win_set_buf(win, occupant.bufnr) end
  for opt, value in pairs(WIN_OPTS) do
    vim.api.nvim_set_option_value(opt, value, { scope = "local", win = win })
  end
  vim.wo[win].winbar = occupant.title and WINBAR or ""
  scroll_to_end(win)
  bind(occupant)
end

---@param step integer
local function cycle(step)
  local win = M.get_win()
  if not win then return end
  local names = vim.tbl_filter(
    function(name) return not shown_in(occupants[name].bufnr, win) end,
    M.names()
  )
  if #names < 2 then return end
  local current = name_of(vim.api.nvim_win_get_buf(win))
  local index = 1
  for i, name in ipairs(names) do
    if name == current then index = i end
  end
  M.show(occupants[names[(index - 1 + step) % #names + 1]], { enter = true })
end

---@param occupant core.pane.Occupant
function bind(occupant)
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
function M.add(occupant) occupants[occupant.name] = occupant end

---@param occupant core.pane.Occupant
---@param opts? { enter?: boolean, insert?: boolean, win?: integer }
---@return integer|nil
function M.show(occupant, opts)
  opts = opts or {}
  if not vim.api.nvim_buf_is_valid(occupant.bufnr) then return nil end
  occupants[occupant.name] = occupant

  local win = shown_in(occupant.bufnr) or (opts.win and is_pane(opts.win) and opts.win) or M.window()
  place(win, occupant)

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

---@param occupant core.pane.Occupant
---@param beside? integer the strip window to open it right of
---@return integer|nil
function M.split(occupant, beside)
  if not vim.api.nvim_buf_is_valid(occupant.bufnr) then return nil end
  local wins = M.wins()
  beside = beside and is_pane(beside) and beside or wins[#wins]
  if not beside then return M.show(occupant) end
  occupants[occupant.name] = occupant
  splitting = true
  local ok, win = pcall(vim.api.nvim_open_win, occupant.bufnr, false, { split = "right", win = beside })
  splitting = false
  if not ok then return nil end
  vim.w[win].core_pane = true
  place(win, occupant)
  return win
end

-- <C-w>v or <C-w>s inside the strip: the new window is part of the strip, and
-- shows what the occupant says a split means rather than the same buffer twice.
function M.on_new_window()
  if splitting then return end
  local win = vim.api.nvim_get_current_win()
  local previous = vim.fn.win_getid(vim.fn.winnr "#")
  if not is_pane(previous) or vim.api.nvim_win_get_config(win).relative ~= "" then return end
  vim.w[win].core_pane = true
  local occupant = occupants[name_of(vim.api.nvim_win_get_buf(win)) or ""]
  if not occupant or not occupant.split then return end
  vim.schedule(function()
    if vim.api.nvim_win_is_valid(win) then occupant.split(win) end
  end)
end

---@return string
function M.winbar()
  local win = vim.g.statusline_winid
  local occupant = occupants[name_of(vim.api.nvim_win_get_buf(win)) or ""]
  if not occupant or not occupant.title then return "" end
  return " " .. occupant.title():gsub("%%", "%%%%")
end

---@param win integer
local function close_win(win)
  if #vim.api.nvim_tabpage_list_wins(0) > 1 then pcall(vim.api.nvim_win_close, win, false) end
end

function M.hide()
  for _, win in ipairs(M.wins()) do
    close_win(win)
  end
end

---@param name string
function M.release(name)
  local occupant = occupants[name]
  if not occupant then return end
  occupants[name] = nil

  for _, win in ipairs(M.wins()) do
    if vim.api.nvim_win_get_buf(win) == occupant.bufnr then
      if #M.wins() > 1 then
        close_win(win)
      else
        local next = vim.tbl_filter(function(other) return not shown_in(occupants[other].bufnr) end, M.names())[1]
        if next then
          place(win, occupants[next])
        else
          close_win(win)
        end
      end
    end
  end
end

---@param bufnr integer
function M.refresh(bufnr)
  local win = M.get_win()
  if win and vim.api.nvim_win_get_buf(win) == bufnr then scroll_to_end(win) end
end

return M
