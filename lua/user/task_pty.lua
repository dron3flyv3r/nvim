-- Keep a running task's pty the same size as the window its output is shown in.
--
-- THE BUG THIS FIXES: run a training script contextually and every tqdm
-- update lands on a NEW LINE -- a wall of half-drawn progress bars scrolling
-- past, instead of one bar filling up in place.
--
-- Overseer starts the process on a pty sized to the whole editor -- literally
-- `vim.o.columns - 4` by `vim.o.lines - 4`, see `strategy/jobstart.lua` -- and
-- then shows the output in the dock, which is half of the bottom strip. On this
-- setup that means the process is told it has a 116x36 terminal while the grid
-- it is actually drawing into is 79x12.
--
-- tqdm believes the pty. It asks the terminal how wide it is (TIOCGWINSZ), is
-- told 116, and draws a 116-cell bar. Neovim's grid wraps that onto two rows,
-- and the `\r` that begins the next update only rewinds the LAST row -- so the
-- row above it stays on screen forever. One orphaned row per update, which is
-- exactly the "it prints instead of redrawing" symptom. Anything that redraws
-- with `\r` is affected the same way: rich, keras, huggingface, wget, pip.
--
-- Sizing the pty to the window fixes it at the source. The bar is drawn to fit
-- the grid, nothing wraps, and `\r` lands where the program meant it to.
--
-- TIMING MATTERS, because tqdm defaults to `dynamic_ncols=False`: it reads the
-- width ONCE, when the bar is constructed, and a resize after that will not fix
-- a bar that already exists. The `FileType OverseerOutput` autocmd below fires
-- from inside `Task:start()`, just after the components have opened the output
-- pane -- milliseconds after the process is spawned and long before Python has
-- finished importing torch, so the first bar is already right. The window
-- events keep it right afterwards, which is what `dynamic_ncols=True` and
-- anything else handling SIGWINCH will pick up.
--
-- Wired up from `lua/plugins/tasks.lua`.
local M = {}

--- The size of the terminal grid Neovim gives `bufnr`, in cells.
---
--- When a terminal buffer is on screen more than once, Neovim sizes the grid to
--- the LARGEST of those windows -- checked: the same buffer in a 39- and a
--- 40-column window gets a 40-column grid. So that is the size to match, not
--- whichever window the cursor happens to be in.
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

--- Match every running task's pty to its output window, on the next tick.
---
--- Deferred for two reasons: on `WinClosed` the window that is going away is
--- still in `nvim_list_wins()`, and dragging a split boundary fires a burst of
--- events that should cost one resize, not twenty.
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

  -- A task started. `Task:start()` sets this filetype on the output buffer
  -- immediately after dispatching `on_start`, which is what opened the pane --
  -- so the window exists by the time we look for it. See the timing note above
  -- for why this cannot wait.
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
