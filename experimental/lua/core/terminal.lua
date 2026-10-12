local M = {}

local NAME = "terminal"
local bufnr
local closing = false
---@type string|string[]|nil
local shell

local function running()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return false end
  local job = vim.b[bufnr].terminal_job_id
  return job and vim.fn.jobwait({ job }, 0)[1] == -1
end

local function close()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  closing = true
  local job = vim.b[bufnr].terminal_job_id
  if job then vim.fn.jobstop(job) end
  require("core.pane").release(NAME)
  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  bufnr = nil
  closing = false
end

local function create()
  bufnr = vim.api.nvim_create_buf(false, true)
  vim.b[bufnr].core_terminal = true
  vim.api.nvim_buf_set_name(bufnr, "terminal://shell")

  local pane = require "core.pane"
  local win = pane.show({ name = NAME, bufnr = bufnr, close = close }, { enter = true })
  if not win then return end

  local cmd = shell or vim.o.shell
  local job = vim.fn.jobstart(cmd, { term = true, cwd = vim.uv.cwd() })
  if job <= 0 then
    close()
    vim.notify(
      "Could not start " .. (type(cmd) == "table" and table.concat(cmd, " ") or cmd),
      vim.log.levels.ERROR,
      { title = "terminal" }
    )
    return
  end
  vim.cmd.startinsert()
end

function M.toggle()
  local pane = require "core.pane"
  if pane.current() == NAME then return pane.hide() end
  if running() then
    pane.show({ name = NAME, bufnr = bufnr, close = close }, { enter = true, insert = true })
  else
    create()
  end
end

---@param buf integer
function M.on_close(buf)
  if closing or buf ~= bufnr then return end
  require("core.pane").release(NAME)
  bufnr = nil
  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(buf) then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
  end)
end

---@return integer|nil
local function editing_window()
  local pane = require("core.pane").get_win()
  local function usable(win) return win ~= 0 and win ~= pane and vim.api.nvim_win_get_config(win).relative == "" end
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

function M.setup() vim.api.nvim_create_user_command("Terminal", M.toggle, {}) end

return M
