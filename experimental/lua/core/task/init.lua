local pane = require "core.pane"

local M = {}

local OCCUPANT = "task"

---@class core.task.Spec
---@field name string
---@field cmd string[]
---@field cwd? string
---@field env? table<string, string>
---@field errorformat? string
---@field queue? boolean
---@field focus? boolean
---@field on_exit? fun(task: core.Task)

---@class core.Task
---@field id integer
---@field name string
---@field cmd string[]
---@field cwd string
---@field bufnr integer
---@field job? integer
---@field status "pending"|"running"|"success"|"failed"|"stopped"
---@field code? integer
---@field started_at? integer
---@field spec core.task.Spec

---@type core.Task[]
local tasks = {}
---@type core.Task[]
local pending = {}
local next_id = 0

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "Tasks" })
end

---@param task core.Task
---@param opts? { enter?: boolean, insert?: boolean }
---@return integer|nil
local function show(task, opts)
  return pane.show({
    name = OCCUPANT,
    bufnr = task.bufnr,
    close = function()
      M.stop(task)
      pane.release(OCCUPANT)
    end,
  }, opts)
end

---@param task core.Task
---@return boolean
local function busy(task) return task ~= nil and (task.status == "running" or task.status == "pending") end

---@return core.Task|nil
local function active()
  for _, task in ipairs(tasks) do
    if task.status == "running" then return task end
  end
end

---@param bufnr integer
---@return string[]
local function output_lines(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return {} end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i = #lines, 1, -1 do
    if lines[i]:match "%S" then break end
    table.remove(lines, i)
  end
  return lines
end

---@param task core.Task
local function to_quickfix(task)
  if not task.spec.errorformat then return end
  -- Compilers emit paths relative to where they ran, but setqflist resolves
  -- them against Neovim's cwd. Parse from the task's directory instead.
  local previous = vim.fn.chdir(task.cwd)
  local ok = pcall(vim.fn.setqflist, {}, " ", {
    title = task.name,
    lines = output_lines(task.bufnr),
    efm = task.spec.errorformat,
  })
  if previous ~= "" then vim.fn.chdir(previous) end
  if not ok then return end

  local count = #vim.fn.getqflist()
  if count > 0 then notify(("%s: %d quickfix entr%s"):format(task.name, count, count == 1 and "y" or "ies")) end
end

---@return core.Task|nil
local function queue_head()
  for _, task in ipairs(tasks) do
    if task.status == "running" and task.spec.queue ~= false then return task end
  end
end

local function pump()
  if queue_head() then return end
  while true do
    local task = table.remove(pending, 1)
    if not task then return end
    if vim.api.nvim_buf_is_valid(task.bufnr) then
      M.start(task)
      return
    end
  end
end

---@param task core.Task
---@param code integer
local function finish(task, code)
  task.job = nil
  task.code = code
  if task.status ~= "stopped" then task.status = code == 0 and "success" or "failed" end

  to_quickfix(task)
  pane.refresh(task.bufnr)

  if task.status == "failed" then
    notify(("%s exited with %d"):format(task.name, code), vim.log.levels.WARN)
    show(task)
  end

  if task.spec.on_exit then pcall(task.spec.on_exit, task) end
  vim.schedule(pump)
end

---@param task core.Task
function M.start(task)
  if task.status == "running" then return task end

  task.status = "running"
  task.started_at = vim.uv.hrtime()

  vim.api.nvim_buf_call(task.bufnr, function()
    task.job = vim.fn.jobstart(task.cmd, {
      term = true,
      cwd = task.cwd,
      env = task.spec.env,
      on_exit = function(_, code) vim.schedule(function() finish(task, code) end) end,
    })
  end)

  if not task.job or task.job <= 0 then
    task.status = "failed"
    notify(("Could not start %s"):format(task.name), vim.log.levels.ERROR)
    vim.schedule(pump)
    return task
  end

  vim.b[task.bufnr].core_task_id = task.id
  show(task, { enter = task.spec.focus == true })
  return task
end

---@param spec core.task.Spec
---@return core.Task
function M.run(spec)
  assert(type(spec.name) == "string" and spec.name ~= "", "task needs a name")
  assert(type(spec.cmd) == "table" and #spec.cmd > 0, "task needs a cmd list")

  next_id = next_id + 1
  local bufnr = vim.api.nvim_create_buf(false, true)

  ---@type core.Task
  local task = {
    id = next_id,
    name = spec.name,
    cmd = spec.cmd,
    cwd = spec.cwd or vim.fn.getcwd(),
    bufnr = bufnr,
    status = "pending",
    spec = spec,
  }
  vim.b[bufnr].core_task_id = task.id
  table.insert(tasks, 1, task)

  if spec.queue == false or not queue_head() then return M.start(task) end

  table.insert(pending, task)
  notify(("%s is %s in the queue"):format(task.name, #pending == 1 and "next" or ("#" .. #pending)))
  return task
end

---@param id? integer|core.Task
---@return core.Task|nil
local function resolve(id)
  if type(id) == "table" then return id end
  if id == nil then return tasks[1] end
  for _, task in ipairs(tasks) do
    if task.id == id then return task end
  end
end

---@param id? integer|core.Task
function M.stop(id)
  local task = resolve(id)
  if not task then return end
  for i, queued in ipairs(pending) do
    if queued == task then
      table.remove(pending, i)
      break
    end
  end
  if task.job then
    task.status = "stopped"
    pcall(vim.fn.jobstop, task.job)
  elseif task.status == "pending" then
    task.status = "stopped"
  end
end

---@param id? integer|core.Task
---@return core.Task|nil
function M.restart(id)
  local task = resolve(id)
  if not task then return end
  M.stop(task)
  return M.run(task.spec)
end

---@return core.Task[]
function M.list() return tasks end

---@return core.Task|nil
function M.last() return tasks[1] end

---@return core.Task|nil
function M.running() return active() end

---@return integer
function M.queued() return #pending end

---@return integer
function M.clear_queue()
  local dropped = #pending
  for _, task in ipairs(pending) do
    task.status = "stopped"
  end
  pending = {}
  return dropped
end

---@param opts? { enter?: boolean, insert?: boolean }
function M.show(opts)
  local task = M.last()
  if not task then
    notify "No task has been run yet"
    return
  end
  if not show(task, opts) then notify "Task has no output yet" end
end

---@type core.ActionProvider
local provider = {
  id = "tasks",
  name = "Tasks",
  priority = 10,

  detect = function()
    local task = M.last()
    if not task then return false end
    return ("%s (%s)"):format(task.name, task.status)
  end,

  actions = function()
    return {
      {
        id = "show",
        label = "Show the last task output",
        category = "Inspect",
        repeatable = false,
        run = function() M.show { enter = true } end,
      },
      {
        id = "restart",
        label = "Restart the last task",
        category = "Run",
        run = function() M.restart() end,
      },
      {
        id = "stop",
        label = "Stop the running task",
        category = "Maintenance",
        available = active() ~= nil or "Nothing is running",
        run = function() M.stop(active()) end,
      },
      {
        id = "clear_queue",
        label = "Clear the task queue",
        category = "Maintenance",
        available = #pending > 0 or "The queue is empty",
        run = function() notify(("Dropped %d queued task(s)"):format(M.clear_queue())) end,
      },
    }
  end,

  status = function()
    local lines = {}
    for i, task in ipairs(tasks) do
      if i > 5 then break end
      lines[#lines + 1] = ("  %s: %s%s"):format(task.name, task.status, task.code and (" (" .. task.code .. ")") or "")
    end
    if #pending > 0 then lines[#lines + 1] = ("  %d queued"):format(#pending) end
    return lines
  end,
}

function M.setup()
  require("core.actions").register(provider)

  vim.api.nvim_create_user_command("TaskOutput", function() M.show { enter = true } end, {
    desc = "Focus the task output pane",
  })
  vim.api.nvim_create_user_command("TaskStop", function() M.stop(active()) end, { desc = "Stop the running task" })
  vim.api.nvim_create_user_command("TaskRestart", function() M.restart() end, { desc = "Restart the last task" })
end

return M
