local cargo = require "lang.rust.cargo"
local tasks = require "core.task"

local M = {}

local GROUP = "lang_rust_watch"

---@alias rust.WatchMode "run"|"build"

---@class rust.Watcher
---@field workspace rust.CargoWorkspace
---@field mode rust.WatchMode
---@field binary? string
---@field args string[]
---@field build? core.Task
---@field process? core.Task
---@field scheduled? boolean
---@field relaunch? boolean

---@type table<string, rust.Watcher>
local watchers = {}

---@type table<string, { binary: string, args: string }>
local remembered = {}

local function notify(message, level) vim.notify(message, level or vim.log.levels.INFO, { title = "Rust watch" }) end

---@param task? core.Task
---@return boolean
local function busy(task) return task ~= nil and (task.status == "running" or task.status == "pending") end

---@param watcher rust.Watcher
---@return boolean
local function current(watcher) return watchers[watcher.workspace.root] == watcher end

---@param watcher rust.Watcher
local function launch(watcher)
  if not current(watcher) then return end
  local program = vim.fs.joinpath(watcher.workspace.target_dir, "debug", watcher.binary)
  watcher.process = tasks.run {
    name = table.concat(vim.list_extend({ watcher.binary }, watcher.args), " "),
    cmd = vim.list_extend({ program }, watcher.args),
    cwd = watcher.workspace.root,
    queue = false,
    on_exit = function(task)
      if task ~= watcher.process or not watcher.relaunch then return end
      watcher.relaunch = false
      launch(watcher)
    end,
  }
end

--- The old process has to be gone before the new one starts, or a server
--- relaunched on top of itself finds its own port still bound.
---@param watcher rust.Watcher
local function relaunch(watcher)
  if not busy(watcher.process) then return launch(watcher) end
  watcher.relaunch = true
  tasks.stop(watcher.process)
end

---@param watcher rust.Watcher
local function rebuild(watcher)
  watcher.scheduled = false
  if not current(watcher) then return end
  if busy(watcher.build) then tasks.stop(watcher.build) end

  local args = watcher.mode == "run" and { "build", "--bin", watcher.binary } or { "build" }
  watcher.build = tasks.run {
    name = "watch: cargo " .. table.concat(args, " "),
    cmd = vim.list_extend({ "cargo" }, args),
    cwd = watcher.workspace.root,
    errorformat = cargo.errorformat,
    on_exit = function(task)
      if task == watcher.build and task.status == "success" and watcher.mode == "run" and current(watcher) then
        relaunch(watcher)
      end
    end,
  }
end

---@param args vim.api.keyset.create_autocmd.callback_args
local function on_write(args)
  if require("core.autosave").writing() then return end
  local file = vim.api.nvim_buf_get_name(args.buf)
  for root, watcher in pairs(watchers) do
    if not watcher.scheduled and vim.fs.relpath(root, file) then
      watcher.scheduled = true
      vim.schedule(function() rebuild(watcher) end)
    end
  end
end

local function listen()
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = vim.api.nvim_create_augroup(GROUP, { clear = true }),
    pattern = { "*.rs", "Cargo.toml" },
    callback = on_write,
  })
end

---@param watcher rust.Watcher
---@return string
function M.describe(watcher)
  if watcher.mode == "build" then return "cargo build" end
  return vim.trim(("%s %s"):format(watcher.binary, table.concat(watcher.args, " ")))
end

---@param root string
---@return rust.Watcher|nil
function M.get(root) return watchers[root] end

---@param root string
---@return { binary: string, args: string }|nil
function M.remembered(root) return remembered[root] end

---@param root string
---@return boolean
function M.stop(root)
  local watcher = watchers[root]
  if not watcher then return false end
  watchers[root] = nil
  watcher.relaunch = false
  for _, task in ipairs { watcher.build, watcher.process } do
    if busy(task) then tasks.stop(task) end
  end
  if next(watchers) == nil then pcall(vim.api.nvim_del_augroup_by_name, GROUP) end
  return true
end

---@param workspace rust.CargoWorkspace
---@param mode rust.WatchMode
---@param binary? string
---@param input? string
function M.start(workspace, mode, binary, input)
  M.stop(workspace.root)
  ---@type rust.Watcher
  local watcher = {
    workspace = workspace,
    mode = mode,
    binary = binary,
    args = vim.split(vim.trim(input or ""), "%s+", { trimempty = true }),
  }
  if binary then
    local memory = remembered[workspace.root] or { args = "" }
    memory.binary = binary
    memory.args = input or memory.args
    remembered[workspace.root] = memory
  end
  watchers[workspace.root] = watcher
  listen()
  rebuild(watcher)
  notify(("Watching %s: rebuilds on :w, not on autosave"):format(M.describe(watcher)))
end

return M
