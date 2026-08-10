-- `<Leader>r` -- running things.
--
-- WHY OVERSEER AND NOT `code_runner.nvim` (which used to live on these keys):
-- code_runner maps a *filetype* to a command -- `python3 $file`, `gcc $file`.
-- That is fine for a scratch script and useless for everything in ~/code. An
-- ESP32 sketch is not built by running gcc on the file you happen to have open;
-- it is built by `just build`, which drives arduino-cli with a board FQBN, two
-- library paths and a partition scheme.
--
-- Overseer reads the project instead. It ships templates for `justfile`,
-- `Makefile`, `CMakeLists.txt`, `package.json` and more, so `<Leader>rr` in
-- SOPA-ESP32-MK3 lists that project's real recipes -- build, flash, monitor --
-- and in a CMake project lists its targets. Nothing to configure per project.
--
-- The other half of the win is the output: overseer parses compiler errors into
-- the quickfix list, so a failed build is something you step through with
-- `æq` / `øq` (`]q` / `[q`) rather than something you read and then go hunting
-- for by hand.
--
-- `astrocommunity.code-runner.overseer-nvim` (see `community.lua`) puts all of
-- this on `<Leader>M`. With code_runner gone, `<Leader>r` is free and is where
-- "run" belongs, so this file moves it and retires the old prefix.

--- Tasks that have actually started, most recently started first.
---
--- `list_tasks()`'s default sort puts tasks that have NOT started first (see
--- `task_list.default_sort`), which with the queue in `user.task_queue` is
--- routinely a task that has not run yet -- never what "the last task" means on
--- these keys. Drop those and sort by start time.
---@return overseer.Task[]
local function started_tasks()
  local task_list = require "overseer.task_list"
  return task_list.list_tasks {
    filter = function(task) return task.time_start ~= nil end,
    sort = task_list.sort_newest_first,
  }
end

--- Running tasks, most recently started first.
---@return overseer.Task[]
local function running_tasks()
  local task_list = require "overseer.task_list"
  return task_list.list_tasks {
    status = require("overseer.constants").STATUS.RUNNING,
    sort = task_list.sort_newest_first,
  }
end

--- The window in this tab already showing `bufnr`, if any.
---@param bufnr integer
---@return integer|nil
local function window_showing(bufnr)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == bufnr then return win end
  end
end

--- Put the cursor in the most recent task's output, opening it if needed.
---
--- The output pane is a terminal buffer, so with the cursor in it and insert
--- mode on, keys go to the process's stdin -- an `input()` prompt, a `[y/N]`, a
--- `Ctrl-C`. `<Esc>` gets back out (AstroNvim maps it in terminal mode).
---@param insert boolean Start insert mode, ready to type at the process.
local function focus_output(insert)
  local task = started_tasks()[1]
  if not task then
    vim.notify("No task has been run yet -- <Leader>rr to start one", vim.log.levels.INFO, { title = "Overseer" })
    return
  end

  -- nil while the task is still PENDING: no process, so no terminal.
  local bufnr = task:get_bufnr()
  if not bufnr then
    vim.notify("Task has not started yet", vim.log.levels.INFO, { title = "Overseer" })
    return
  end

  local win = window_showing(bufnr)
  if not win then
    -- Either the strip is closed, or it is open on a different task.
    -- `focus_task_id` covers both: it opens if needed, and points the output
    -- pane at this task.
    require("overseer.window").open { direction = "bottom", enter = false, focus_task_id = task.id }
    win = window_showing(bufnr)
  end
  -- Last resort if the dock refuses to show it -- a plain split of the terminal
  -- buffer is just as readable.
  if not win then
    task:open_output "horizontal"
    win = vim.api.nvim_get_current_win()
  end

  vim.api.nvim_set_current_win(win)
  if insert and vim.bo[bufnr].buftype == "terminal" then vim.cmd.startinsert() end
end

---@type LazySpec
return {
  "stevearc/overseer.nvim",
  opts = {
    task_list = {
      -- Bottom of the screen, full width. The default is a right-hand sidebar,
      -- which on a widescreen steals a column you would rather have as code --
      -- and task output is wide, wrapped text that reads better long than tall.
      direction = "bottom",
      min_height = 12,
    },

    output = {
      -- A real terminal buffer, not a plain one. This is what makes a live run
      -- watchable: tqdm and torch progress bars redraw in place instead of
      -- printing one line per update, colours survive, and -- because it is a
      -- terminal -- typing in the window goes to the process's stdin, so an
      -- `input()` prompt or a `y/n` confirmation is answerable.
      use_terminal = true,
    },

    component_aliases = {
      -- Overseer's own `default` alias, PLUS `open_output`. Listing the three
      -- builtins again is not redundant: setting this key replaces the alias
      -- outright rather than merging into it.
      default = {
        "on_exit_set_status",
        "on_complete_notify",
        { "on_complete_dispose", require_view = { "SUCCESS", "FAILURE" } },

        -- The reason a task used to run invisibly. Without this, starting a
        -- task only put a line in a task list you had to go open yourself.
        {
          "open_output",
          -- `dock` splits the bottom strip in two: task list on the left,
          -- the selected task's live output on the right, scrolled to the end
          -- as it arrives. On a widescreen that is the whole point -- status
          -- and output side by side without giving up a code column.
          direction = "dock",
          -- The default here is "if_no_on_output_quickfix", which would keep
          -- the Python tasks silent, since those parse tracebacks.
          on_start = "always",
          -- Do NOT steal the cursor: the run keeps you in your file, which is
          -- what you want while a build churns. `<Leader>ri` goes there and
          -- into insert mode for the times the process wants an answer.
          focus = false,
        },
      },
    },
  },
  dependencies = {
    {
      "AstroNvim/astrocore",
      ---@param opts AstroCoreOpts
      opts = function(_, opts)
        -- Guaranteed by `astrocore.lua`, which sets `mappings` in its static opts.
        local maps = assert(opts.mappings)
        local icon = require("astroui").get_icon("Overseer", 1, true)

        -- Retire the astrocommunity default prefix so there is one way to do
        -- this, not two. (`false` removes a mapping in AstroCore.)
        --
        -- NOTE THE LOWERCASE `<leader>`: these are plain Lua table keys, so the
        -- spelling has to match the one astrocommunity used *character for
        -- character*. `<Leader>Mt` and `<leader>Mt` are two different entries
        -- and disabling one leaves the other registered.
        maps.n["<leader>M"] = false
        for _, key in ipairs { "t", "c", "r", "a", "i" } do
          maps.n["<leader>M" .. key] = false
        end

        maps.n["<Leader>r"] = { desc = icon .. "Run" }

        -- The one you press: pick a task from whatever the project offers.
        maps.n["<Leader>rr"] = { "<Cmd>OverseerRun<CR>", desc = "Run task" }
        -- The one you press repeatedly. Overseer has no "restart last" command,
        -- so reach into the task list for the most recent one and restart it.
        maps.n["<Leader>rl"] = {
          function()
            local tasks = started_tasks()
            if vim.tbl_isempty(tasks) then
              vim.notify(
                "No task has been run yet -- <Leader>rr to start one",
                vim.log.levels.INFO,
                { title = "Overseer" }
              )
              return
            end
            require("overseer").run_action(tasks[1], "restart")
          end,
          desc = "Re-run last task",
        }
        -- Run THIS file, no picker. `<Leader>rl` re-runs whatever ran last,
        -- which is what you want while iterating on one thing -- but the moment
        -- you move from lec5 to lec6 it is still pointing at lec5. This is the
        -- "run what I'm looking at" key that switches the target.
        --
        -- Python only for now: it is the language here where the *right*
        -- command (`python -m lec6.main`, from the project root) is not the
        -- obvious one. C/C++ is driven by the justfile, which overseer already
        -- reads, so `<Leader>rr` covers it.
        maps.n["<Leader>rf"] = {
          function()
            local target = require("user.python_target").resolve()
            if not target then
              vim.notify("Not a Python file -- use <Leader>rr", vim.log.levels.WARN, { title = "Run" })
              return
            end
            if not target.module then
              vim.notify("File is outside the project root", vim.log.levels.WARN, { title = "Run" })
              return
            end
            require("overseer").run_task {
              name = require("user.python_target").module_template_name(target),
              first = true,
            }
          end,
          desc = "Run this file (python -m ...)",
        }

        -- Type INTO the running task, and just look at it, respectively.
        maps.n["<Leader>ri"] = {
          function() focus_output(true) end,
          desc = "Focus task output (type into it)",
        }
        maps.n["<Leader>ro"] = {
          function() focus_output(false) end,
          desc = "Open last task output",
        }

        -- Run it, but not now. Overseer starts every task the moment you pick
        -- it, so two presses of `<Leader>rr` means two processes competing for
        -- the GPU / the build dir / the serial port. This picks a task the same
        -- way and parks it until the current one is done.
        maps.n["<Leader>rq"] = {
          function()
            local queue = require "user.task_queue"
            require("overseer").run_task({ autostart = false }, function(task, err)
              if not task then
                -- No error along with it means you backed out of the task's
                -- parameter form. (Backing out of the template picker itself
                -- never calls us at all.)
                if err then vim.notify(err, vim.log.levels.ERROR, { title = "Task queue" }) end
                return
              end
              local ahead = queue.enqueue(task)
              if ahead == 0 then
                vim.notify(("Running %s"):format(task.name), vim.log.levels.INFO, { title = "Task queue" })
              else
                vim.notify(
                  ("Queued %s -- %d task%s ahead of it"):format(task.name, ahead, ahead == 1 and "" or "s"),
                  vim.log.levels.INFO,
                  { title = "Task queue" }
                )
              end
            end)
          end,
          desc = "Queue task (run after the current one)",
        }

        -- Kill the current run. `Ctrl-C` in the output pane only reaches the
        -- process if it is listening for it; this stops the job outright.
        maps.n["<Leader>rk"] = {
          function()
            local tasks = running_tasks()
            if vim.tbl_isempty(tasks) then
              vim.notify("Nothing is running", vim.log.levels.INFO, { title = "Overseer" })
              return
            end
            local task = tasks[1]
            task:stop()
            local rest = #tasks - 1
            vim.notify(
              ("Stopped %s%s"):format(task.name, rest > 0 and (" (%d still running)"):format(rest) or ""),
              vim.log.levels.WARN,
              { title = "Overseer" }
            )
          end,
          desc = "Kill the running task",
        }

        -- The panic key: everything stops, nothing waiting starts.
        maps.n["<Leader>rK"] = {
          function()
            local tasks = running_tasks()
            for _, task in ipairs(tasks) do
              task:stop()
            end
            local dropped = require("user.task_queue").clear()
            if vim.tbl_isempty(tasks) and dropped == 0 then
              vim.notify("Nothing is running or queued", vim.log.levels.INFO, { title = "Overseer" })
              return
            end
            vim.notify(
              ("Stopped %d, dropped %d queued"):format(#tasks, dropped),
              vim.log.levels.WARN,
              { title = "Overseer" }
            )
          end,
          desc = "Kill everything (running + queued)",
        }

        maps.n["<Leader>rt"] = { "<Cmd>OverseerToggle<CR>", desc = "Toggle task list" }
        maps.n["<Leader>rc"] = { "<Cmd>OverseerShell<CR>", desc = "Run shell command" }
        maps.n["<Leader>ra"] = { "<Cmd>OverseerTaskAction<CR>", desc = "Task action (stop, restart, ...)" }
      end,
    },
  },
}
