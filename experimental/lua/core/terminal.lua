local M = {}

---@class core.terminal.Shell
---@field id integer
---@field bufnr integer
---@field name string
---@field cwd string
---@field occupant core.pane.Occupant

---@class core.terminal.Slot
---@field shell core.terminal.Shell
---@field width integer

---@type core.terminal.Shell[]
local shells = {}
---@type core.terminal.Shell|nil
local last
---@type core.terminal.Slot[]
local hidden_layout = {}
local hidden_height
local next_id = 1
local closing = false
---@type string|string[]|nil
local shell

---@param bufnr integer
---@return core.terminal.Shell|nil, integer|nil
local function find(bufnr)
  for i, entry in ipairs(shells) do
    if entry.bufnr == bufnr then return entry, i end
  end
end

---@param entry core.terminal.Shell
local function running(entry)
  if not vim.api.nvim_buf_is_valid(entry.bufnr) then return false end
  local job = vim.b[entry.bufnr].terminal_job_id
  return job and vim.fn.jobwait({ job }, 0)[1] == -1
end

---@param entry core.terminal.Shell
---@return string
local function cwd_of(entry)
  if running(entry) then
    local ok, pid = pcall(vim.fn.jobpid, vim.b[entry.bufnr].terminal_job_id)
    local cwd = ok and vim.uv.fs_readlink("/proc/" .. pid .. "/cwd")
    if cwd then return cwd end
  end
  return entry.cwd
end

---@param entry core.terminal.Shell
local function forget(entry)
  local _, index = find(entry.bufnr)
  if index then table.remove(shells, index) end
  if last == entry then last = shells[#shells] end
  if #shells == 0 then next_id = 1 end
  require("core.pane").release(entry.name)
end

---@param entry core.terminal.Shell
local function close(entry)
  if not vim.api.nvim_buf_is_valid(entry.bufnr) then return forget(entry) end
  closing = true
  local job = vim.b[entry.bufnr].terminal_job_id
  if job then vim.fn.jobstop(job) end
  forget(entry)
  pcall(vim.api.nvim_buf_delete, entry.bufnr, { force = true })
  closing = false
end

local start

---@param opts { cwd?: string, win?: integer, beside?: integer, enter?: boolean, hidden?: boolean }
---@return core.terminal.Shell|nil
function start(opts)
  local pane = require "core.pane"
  local id = next_id
  next_id = next_id + 1
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.b[bufnr].core_terminal = true
  vim.api.nvim_buf_set_name(bufnr, "terminal://shell/" .. id)
  local cwd = opts.cwd or vim.uv.cwd() or vim.fn.getcwd()
  ---@type core.terminal.Shell
  local entry = { id = id, bufnr = bufnr, name = "terminal " .. id, cwd = cwd, occupant = nil }
  entry.occupant = {
    name = entry.name,
    bufnr = bufnr,
    close = function() close(entry) end,
    split = function(win) start { win = win, enter = true } end,
    title = function() return ("Terminal %d  ·  %s"):format(id, vim.fn.fnamemodify(cwd_of(entry), ":~")) end,
  }
  shells[#shells + 1] = entry
  last = entry

  local win
  if opts.hidden then
    pane.add(entry.occupant)
  elseif opts.beside then
    win = pane.split(entry.occupant, opts.beside)
  else
    win = pane.show(entry.occupant, { win = opts.win })
  end
  if not opts.hidden and not win then
    close(entry)
    return
  end

  local cmd = shell or vim.o.shell
  local job
  vim.api.nvim_buf_call(bufnr, function() job = vim.fn.jobstart(cmd, { term = true, cwd = cwd }) end)
  if job <= 0 then
    close(entry)
    vim.notify(
      "Could not start " .. (type(cmd) == "table" and table.concat(cmd, " ") or cmd),
      vim.log.levels.ERROR,
      { title = "terminal" }
    )
    return
  end
  if opts.enter and win then
    vim.api.nvim_set_current_win(win)
    vim.cmd.startinsert()
  end
  return entry
end

---@return core.terminal.Slot[], integer|nil
local function layout()
  local slots, height = {}, nil
  for _, win in ipairs(require("core.pane").wins()) do
    local entry = find(vim.api.nvim_win_get_buf(win))
    if entry then
      slots[#slots + 1] = { shell = entry, width = vim.api.nvim_win_get_width(win) }
      height = height or vim.api.nvim_win_get_height(win)
    end
  end
  return slots, height
end

---@param slots core.terminal.Slot[]
---@param height integer|nil
---@param enter boolean
local function apply(slots, height, enter)
  local pane = require "core.pane"
  local wins = {}
  for i, slot in ipairs(slots) do
    wins[i] = i == 1 and pane.show(slot.shell.occupant) or pane.split(slot.shell.occupant, wins[i - 1])
  end
  for i = 1, #wins - 1 do
    if wins[i] then vim.api.nvim_win_set_width(wins[i], slots[i].width) end
  end
  if height and wins[1] then vim.api.nvim_win_set_height(wins[1], height) end
  if not enter then return end
  local target = wins[1]
  for i, slot in ipairs(slots) do
    if slot.shell == last and wins[i] then target = wins[i] end
  end
  if target then
    vim.api.nvim_set_current_win(target)
    vim.cmd.startinsert()
  end
end

function M.toggle()
  local pane = require "core.pane"
  local win = pane.get_win()
  if win and find(vim.api.nvim_win_get_buf(win)) then
    hidden_layout, hidden_height = layout()
    return pane.hide()
  end
  local slots = vim.tbl_filter(function(slot) return running(slot.shell) end, hidden_layout)
  if #slots > 1 then return apply(slots, hidden_height, true) end
  if last and running(last) then return pane.show(last.occupant, { enter = true, insert = true }) end
  start { enter = true }
end

function M.new() start { enter = true } end

---@param buf integer
function M.on_enter(buf)
  local entry = find(buf)
  if entry then last = entry end
end

---@param buf integer
function M.on_close(buf)
  if closing then return end
  local entry = find(buf)
  if not entry then return end
  forget(entry)
  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(buf) then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
  end)
end

---@return table|nil
local function snapshot()
  if #shells == 0 then return nil end
  local index = {}
  local saved = {}
  for i, entry in ipairs(shells) do
    index[entry] = i
    saved[i] = { cwd = cwd_of(entry) }
  end
  local slots, height = layout()
  local visible = vim.tbl_map(function(slot) return { shell = index[slot.shell], width = slot.width } end, slots)
  return { shells = saved, visible = visible, height = height, last = last and index[last] }
end

---@param data table
local function restore(data)
  if #shells > 0 or type(data.shells) ~= "table" then return end
  local return_to = vim.api.nvim_get_current_win()
  local started = {}
  for i, saved in ipairs(data.shells) do
    local cwd = type(saved.cwd) == "string" and vim.fn.isdirectory(saved.cwd) == 1 and saved.cwd or nil
    started[i] = start { cwd = cwd, hidden = true }
  end
  last = started[data.last] or last
  local slots = {}
  for _, slot in ipairs(data.visible or {}) do
    if started[slot.shell] then slots[#slots + 1] = { shell = started[slot.shell], width = slot.width } end
  end
  apply(slots, data.height, false)
  if vim.api.nvim_win_is_valid(return_to) then vim.api.nvim_set_current_win(return_to) end
end

---@return integer|nil
local function editing_window()
  local function usable(win)
    return win ~= 0 and not vim.w[win].core_pane and vim.api.nvim_win_get_config(win).relative == ""
  end
  local previous = vim.fn.win_getid(vim.fn.winnr "#")
  if usable(previous) then return previous end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if usable(win) then return win end
  end
end

---@param paths string[]
---@return integer
function M.open(paths)
  vim.schedule(function()
    local win = editing_window()
    if win then
      vim.api.nvim_set_current_win(win)
    else
      vim.cmd "topleft split"
    end
    for _, path in ipairs(paths) do
      vim.cmd.drop(vim.fn.fnameescape(path))
    end
    vim.cmd.stopinsert()
  end)
  return 1
end

---@param cmd string|string[]
function M.set_shell(cmd) shell = cmd end

function M.setup()
  vim.api.nvim_create_user_command("Terminal", M.toggle, {})
  vim.api.nvim_create_user_command("TerminalNew", M.new, {})
  require("core.session").register("terminal", { save = snapshot, restore = restore })
end

return M
