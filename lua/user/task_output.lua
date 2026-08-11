-- The window a task's output is shown in: one full-width strip along the
-- bottom, reused by every task that runs.
--
-- WHY NOT OVERSEER'S `dock`, which is what `<Leader>r` used before: the dock
-- splits the bottom strip in two, task list on the left and output on the
-- right. The list is not a thin gutter -- overseer floors it at
-- `min_width = { 40, 0.1 }` and then settles on the midpoint of min and max, so
-- it takes 40-odd columns on any screen and the output gets whatever is left.
-- For a run you are actually watching that is the wrong trade: a tqdm bar, a
-- traceback, a table of metrics all want width, while the list is spending it
-- on one line per task whose contents you already know. So the output takes the
-- whole strip, and the task list moved to `<Leader>rt`, on demand.
--
-- WHY NOT `direction = "horizontal"` on overseer's own `open_output`: it runs a
-- plain `:split` from wherever the cursor happens to be, so the output lands
-- mid-layout at half the height of the window you were in -- and every task
-- start stacks another one. This module keeps exactly one pane, always at the
-- bottom, always full width.
--
-- Used by the `user_output_pane` component (which opens it when a task starts)
-- and by `<Leader>ro` / `<Leader>ri` in `lua/plugins/tasks.lua`.
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

  -- THE ONE THAT BIT US. AstroNvim runs `wrap = false` with
  -- `sidescrolloff = 8` (`lua/plugins/astrocore.lua`), and overseer tails
  -- output by parking the cursor at the END of the last line. A terminal line
  -- is exactly as wide as the grid, so keeping 8 columns of context to the
  -- right of that cursor scrolls the whole view sideways -- and the first
  -- seven or eight columns of every line disappear off the left edge. A tqdm
  -- bar loses its `100%|` and the process's exit line reads `s exited 0]`.
  --
  -- A terminal grid can never produce a line wider than the window it is drawn
  -- in, so wrapping costs nothing here and removes horizontal scrolling
  -- outright. `sidescrolloff` goes to 0 as well, for the moment after a resize
  -- when lines drawn at the old width are still longer than the new one.
  wrap = true,
  sidescrolloff = 0,

  -- The output is read, not edited. Cursor decorations on a live progress bar
  -- are noise.
  cursorline = false,
  cursorcolumn = false,
  list = false,
  spell = false,
}

--- Overseer tags every output buffer with the id of the task it belongs to,
--- which is the only reliable way to recognise one: it is a scratch terminal
--- buffer with no name and no distinguishing filetype until `Task:start()` sets
--- one, and this has to work before that point.
---@param bufnr integer
---@return boolean
local function is_output_buf(bufnr) return vim.b[bufnr].overseer_task ~= nil end

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
    -- Splitting from a floating window splits the float. A task can start with
    -- one focused -- overseer's own parameter form, or a picker that has not
    -- finished closing -- so step out to a normal window first. (Overseer
    -- guards its terminal creation the same way, for the same reason.)
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

  -- Neovim sizes the terminal grid from the window, but only re-measures when
  -- the WINDOW's size changes. Clearing 'number', 'signcolumn' and
  -- 'foldcolumn' just now widened the text area by seven columns without
  -- telling the terminal, so the grid would sit seven columns narrower than
  -- the window it is drawn in -- and since `user.task_pty` sizes the pty to
  -- the window, that is a progress bar wrapping again. A one-line nudge forces
  -- the re-measure, and then grid, window and pty all agree.
  local height = vim.api.nvim_win_get_height(win)
  vim.api.nvim_win_set_height(win, height - 1)
  vim.api.nvim_win_set_height(win, height)

  -- Tail the output, the way the dock did.
  require("overseer.util").scroll_to_end(win)

  -- `q` closes the strip, matching the task list's own `q`. Normal mode only,
  -- so typing `q` at a prompt still goes to the process.
  vim.keymap.set("n", "q", "<Cmd>close<CR>", { buffer = bufnr, desc = "Close task output" })

  if opts.enter then
    vim.api.nvim_set_current_win(win)
    if opts.insert and vim.bo[bufnr].buftype == "terminal" then vim.cmd.startinsert() end
  end
  return win
end

return M
