local M = {}

--- How tall the strip is, in lines.
local HEIGHT = 15

--- Window options for the strip. Overseer's `set_term_window_opts` sets the
--- first three and stops; the rest are ours, and each one is load-bearing.
local WIN_OPTS = {
  number = false,
  relativenumber = false,
  signcolumn = "no",
  -- AstroNvim sets this to "1". One more column the output does not get, and
  -- one more column of disagreement between the window and the pty.
  foldcolumn = "0",

  wrap = true,
  sidescrolloff = 0,

  -- The output is read, not edited. Cursor decorations on a live progress bar
  -- are noise.
  cursorline = false,
  cursorcolumn = false,
  list = false,
  spell = false,
}

---@param bufnr integer
---@return boolean
local function is_output_buf(bufnr) return vim.b[bufnr].overseer_task ~= nil end

---@param stop boolean
local function close_output(stop)
  local bufnr = vim.api.nvim_get_current_buf()
  if stop then
    local task = require("overseer.task_list").get(vim.b[bufnr].overseer_task)
    local running = require("overseer.constants").STATUS.RUNNING
    if task and task.status == running then task:stop() end
  end
  vim.cmd.close()
end

--- The output strip in this tab, if it is open.
---@return integer|nil winid
function M.get_win()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    -- Skip floats: `<C-f>` from the task list opens output in one, and that is
    -- a window you dismiss, not the strip we manage.
    if vim.api.nvim_win_get_config(win).relative == "" and is_output_buf(vim.api.nvim_win_get_buf(win)) then
      return win
    end
  end
end

--- Show `task`'s output in the bottom strip, opening the strip if it is closed.
---@param task overseer.Task
---@param opts? {enter?: boolean, insert?: boolean}
---@return integer|nil winid nil when the task has no output buffer yet
function M.open(task, opts)
  opts = opts or {}
  local bufnr = task:get_bufnr()
  -- nil while the task is still PENDING: no process, so no terminal.
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end

  local win = M.get_win()
  if not win then
    local return_to = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_get_config(0).relative ~= "" then
      for _, candidate in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.api.nvim_win_get_config(candidate).relative == "" then
          vim.api.nvim_set_current_win(candidate)
          break
        end
      end
    end
    -- `botright` rather than a plain `split`: the strip spans the full width
    -- and sits at the bottom no matter which window the cursor was in.
    vim.cmd(("noautocmd botright %dsplit"):format(HEIGHT))
    win = vim.api.nvim_get_current_win()
    -- Opening splits elsewhere must not shrink the strip out from under a run.
    vim.wo[win].winfixheight = true
    if vim.api.nvim_win_is_valid(return_to) then vim.api.nvim_set_current_win(return_to) end
  end

  if vim.api.nvim_win_get_buf(win) ~= bufnr then vim.api.nvim_win_set_buf(win, bufnr) end

  for opt, value in pairs(WIN_OPTS) do
    vim.api.nvim_set_option_value(opt, value, { scope = "local", win = win })
  end

  local height = vim.api.nvim_win_get_height(win)
  vim.api.nvim_win_set_height(win, height - 1)
  vim.api.nvim_win_set_height(win, height)

  -- Tail the output, the way the dock did.
  require("overseer.util").scroll_to_end(win)

  -- Normal mode owns pane controls; in Terminal mode both letters still go to
  -- an interactive process as ordinary input.
  vim.keymap.set("n", "h", function() close_output(false) end, { buffer = bufnr, desc = "Hide task output" })
  vim.keymap.set("n", "q", function() close_output(true) end, { buffer = bufnr, desc = "Stop task and hide output" })

  if opts.enter then
    vim.api.nvim_set_current_win(win)
    if opts.insert and vim.bo[bufnr].buftype == "terminal" then vim.cmd.startinsert() end
  end
  return win
end

return M
