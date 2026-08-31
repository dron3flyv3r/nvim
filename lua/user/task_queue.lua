-- A serial run queue for overseer tasks.
--
-- Overseer starts everything immediately: press `<Leader>rr` twice and you get
-- two processes fighting over the same GPU, the same build directory or the
-- same serial port. This module is the "…after the current one" answer: a task
-- is created but left PENDING, and only started once whatever is running has
-- finished.
--
-- The queue is deliberately *not* limited to tasks it started itself. If a
-- build kicked off with `<Leader>rr` is already running when you queue
-- something, that build becomes the thing we wait on -- which is what you meant
-- by "run this next".
--
-- Used by the queue and stop-all contextual task actions.
local M = {}

---Created with `autostart = false`, in the order they will run.
---@type overseer.Task[]
local queue = {}

---The task the queue is waiting on before starting the next one. May be a task
---the queue never started -- see the note about adoption above.
---@type overseer.Task|nil
local blocker = nil

---@param task overseer.Task|nil
---@return boolean
local function busy(task)
  return task ~= nil and not task:is_disposed() and (task:is_running() or task:is_pending())
end

---Wait for `task` to finish (or vanish), then start the next queued task.
---@param task overseer.Task
local function wait_for(task)
  blocker = task
  -- `on_complete` and `on_dispose` can both fire for the same task -- a task
  -- that completes is disposed moments later -- and a task killed while PENDING
  -- only ever fires the latter. Take whichever comes first, once.
  local fired = false
  local function resume()
    if fired then return true end
    fired = true
    if blocker == task then blocker = nil end
    -- We are inside overseer's dispatch loop; let it unwind before spawning the
    -- next process.
    vim.schedule(M.pump)
    return true -- truthy return unsubscribes
  end
  task:subscribe("on_complete", resume)
  task:subscribe("on_dispose", resume)
end

---Start the next queued task, if nothing is in the way.
function M.pump()
  if busy(blocker) then return end
  blocker = nil
  while true do
    local task = table.remove(queue, 1)
    if not task then return end
    if not task:is_disposed() then
      if task:start() then
        wait_for(task)
        return
      end
      -- `start()` refused: a component vetoed it, or the strategy failed. It
      -- will never run and never fire `on_complete`, so drop it rather than let
      -- it wedge everything behind it.
      vim.notify(
        ("Could not start %q -- skipping it"):format(task.name),
        vim.log.levels.WARN,
        { title = "Task queue" }
      )
    end
  end
end

---Queue a task. Starts it immediately if the coast is clear.
---@param task overseer.Task A task created with `autostart = false`.
---@return integer waiting Number of tasks that must finish before this one runs.
function M.enqueue(task)
  table.insert(queue, task)

  if not busy(blocker) then
    -- Nothing of ours is running, but something else may be. Queue behind it.
    local running = require("overseer").list_tasks {
      status = require("overseer.constants").STATUS.RUNNING,
      sort = require("overseer.task_list").sort_newest_first,
    }
    if running[1] then wait_for(running[1]) end
  end

  M.pump()

  -- Report where it actually landed rather than where we predicted: `pump()`
  -- may have started it, or may have started something that was queued ahead.
  if task:is_running() then return 0 end
  for i, queued in ipairs(queue) do
    if queued == task then return i end
  end
  return 0
end

---How many tasks are waiting to start.
---@return integer
function M.len() return #queue end

---Drop everything still waiting. Does not touch the running task.
---@return integer dropped
function M.clear()
  local dropped = 0
  for _, task in ipairs(queue) do
    if not task:is_disposed() then
      task:dispose(true)
      dropped = dropped + 1
    end
  end
  queue = {}
  return dropped
end

return M
