local M = {}

---@param bufnr integer
---@return integer|nil width nil when the buffer is not on screen at all
---@return integer|nil height
local function grid_size(bufnr)
  local width, height
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      local info = vim.fn.getwininfo(win)[1]
      if info then
        -- `width` includes the sign / number / fold columns; the terminal only
        -- ever draws into the text area, which is what `textoff` takes off.
        width = math.max(width or 0, info.width - info.textoff)
        height = math.max(height or 0, info.height)
      end
    end
  end
  return width, height
end

--- The size last sent to each job, so a burst of window events is not a burst
--- of SIGWINCHs at a process that is trying to get work done.
---@type table<integer, string>
local sent = {}

---@param task overseer.Task
local function sync(task)
  -- Only the jobstart strategy owns a pty. `job_id` is nil for a task that has
  -- not started, and absent entirely on any other strategy.
  local job_id = task.strategy and task.strategy.job_id
  if type(job_id) ~= "number" or job_id <= 0 then return end

  local bufnr = task:get_bufnr()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  -- With `output.use_terminal = false` there is no grid and no pty to match.
  if vim.bo[bufnr].buftype ~= "terminal" then return end

  local width, height = grid_size(bufnr)
  -- Not on screen: there is no size to match. Leave the pty alone rather than
  -- shrink it to nothing -- closing the output pane must not make a running job
  -- rewrap its output.
  if not width or width < 1 or not height or height < 1 then return end

  local size = width .. "x" .. height
  if sent[job_id] == size then return end
  -- Racy by nature: a task listed as RUNNING can exit before we get here, and
  -- `jobresize` throws on a dead channel.
  if pcall(vim.fn.jobresize, job_id, width, height) then
    sent[job_id] = size
  else
    sent[job_id] = nil
  end
end

local scheduled = false

local function sync_all()
  if scheduled then return end
  scheduled = true
  vim.schedule(function()
    scheduled = false
    -- No task has ever run, so there is nothing to resize -- and no reason to
    -- drag overseer in just because a window changed size.
    if not package.loaded["overseer"] then return end
    local tasks = require("overseer.task_list").list_tasks {
      status = require("overseer.constants").STATUS.RUNNING,
    }
    for _, task in ipairs(tasks) do
      sync(task)
    end
  end)
end

function M.setup()
  local group = vim.api.nvim_create_augroup("user_task_pty", { clear = true })

  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "OverseerOutput",
    desc = "Match a starting task's pty to its output window",
    callback = sync_all,
  })

  -- Everything that can change that size afterwards: dragging a split,
  -- toggling the task list or opening the output
  -- somewhere else, resizing the terminal Neovim itself runs in.
  vim.api.nvim_create_autocmd({ "WinResized", "WinClosed", "BufWinEnter", "VimResized", "TabEnter" }, {
    group = group,
    desc = "Keep running tasks' ptys matched to their output windows",
    callback = sync_all,
  })
end

return M
