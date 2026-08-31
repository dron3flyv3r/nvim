-- Shared task operations used by mappings and contextual actions.
local M = {}

function M.started()
  local list = require "overseer.task_list"
  return list.list_tasks {
    filter = function(task) return task.time_start ~= nil end,
    sort = list.sort_newest_first,
  }
end

function M.running()
  local list = require "overseer.task_list"
  return list.list_tasks {
    status = require("overseer.constants").STATUS.RUNNING,
    sort = list.sort_newest_first,
  }
end

function M.run_picker() vim.cmd "OverseerRun" end

function M.rerun_last()
  local tasks = M.started()
  if vim.tbl_isempty(tasks) then
    vim.notify("No task has been run yet -- <Leader>ra lists runnable actions", vim.log.levels.INFO, { title = "Tasks" })
    return
  end
  require("overseer").run_action(tasks[1], "restart")
end

function M.focus_output(insert)
  local task = M.started()[1]
  if not task then
    vim.notify("No task has been run yet", vim.log.levels.INFO, { title = "Tasks" })
    return
  end
  if not require("user.task_output").open(task, { enter = true, insert = insert == true }) then
    vim.notify("Task has not started yet", vim.log.levels.INFO, { title = "Tasks" })
  end
end

function M.stop()
  local tasks = M.running()
  if vim.tbl_isempty(tasks) then
    vim.notify("Nothing is running", vim.log.levels.INFO, { title = "Tasks" })
    return
  end
  tasks[1]:stop()
  vim.notify(("Stopped %s"):format(tasks[1].name), vim.log.levels.WARN, { title = "Tasks" })
end

function M.stop_all()
  local tasks = M.running()
  for _, task in ipairs(tasks) do
    task:stop()
  end
  local dropped = require("user.task_queue").clear()
  vim.notify(("Stopped %d, dropped %d queued"):format(#tasks, dropped), vim.log.levels.WARN, { title = "Tasks" })
end

function M.queue()
  local queue = require "user.task_queue"
  require("overseer").run_task({ autostart = false }, function(task, err)
    if not task then
      if err then vim.notify(err, vim.log.levels.ERROR, { title = "Task queue" }) end
      return
    end
    local ahead = queue.enqueue(task)
    vim.notify(ahead == 0 and ("Running %s"):format(task.name) or ("Queued %s -- %d ahead"):format(task.name, ahead), vim.log.levels.INFO, { title = "Task queue" })
  end)
end

return M
