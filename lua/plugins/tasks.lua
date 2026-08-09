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
            local tasks = require("overseer").list_tasks { recent_first = true }
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

        -- Type INTO the running task. The output pane is a terminal buffer, so
        -- once the cursor is in it and you are in insert mode, keys go to the
        -- process's stdin -- an `input()` prompt, a `[y/N]`, a `Ctrl-C`.
        --
        -- `<Esc>` gets you back out (AstroNvim maps it in terminal mode), and
        -- `<Leader>rt` closes the whole strip.
        maps.n["<Leader>ri"] = {
          function()
            local overseer = require "overseer"

            --- The window in this tab already showing `bufnr`, if any.
            local function window_showing(bufnr)
              for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
                if vim.api.nvim_win_get_buf(win) == bufnr then return win end
              end
            end

            local tasks = overseer.list_tasks { recent_first = true }
            if vim.tbl_isempty(tasks) then
              vim.notify("No task is running -- <Leader>rr to start one", vim.log.levels.INFO, { title = "Overseer" })
              return
            end

            local task = tasks[1]
            -- nil while the task is still PENDING: no process, so no terminal.
            local bufnr = task:get_bufnr()
            if not bufnr then
              vim.notify("Task has not started yet", vim.log.levels.INFO, { title = "Overseer" })
              return
            end

            local win = window_showing(bufnr)
            if not win then
              -- Either the strip is closed, or it is open on a different task.
              -- `focus_task_id` covers both: it opens if needed, and points the
              -- output pane at this task.
              require("overseer.window").open { direction = "bottom", enter = false, focus_task_id = task.id }
              win = window_showing(bufnr)
            end
            -- Last resort if the dock refuses to show it -- a plain split of
            -- the terminal buffer is just as typeable.
            if not win then
              task:open_output "horizontal"
              win = vim.api.nvim_get_current_win()
            end

            vim.api.nvim_set_current_win(win)
            if vim.bo[bufnr].buftype == "terminal" then vim.cmd.startinsert() end
          end,
          desc = "Focus task output (type into it)",
        }

        maps.n["<Leader>rt"] = { "<Cmd>OverseerToggle<CR>", desc = "Toggle task list" }
        maps.n["<Leader>rc"] = { "<Cmd>OverseerShell<CR>", desc = "Run shell command" }
        maps.n["<Leader>ra"] = { "<Cmd>OverseerTaskAction<CR>", desc = "Task action (stop, restart, ...)" }
        maps.n["<Leader>rq"] = { "<Cmd>OverseerQuickAction open output<CR>", desc = "Open last task output" }
      end,
    },
  },
}
