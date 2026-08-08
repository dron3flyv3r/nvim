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
  },
  dependencies = {
    {
      "AstroNvim/astrocore",
      ---@type AstroCoreOpts
      opts = function(_, opts)
        local maps = opts.mappings
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
              vim.notify("No task has been run yet -- <Leader>rr to start one", vim.log.levels.INFO, { title = "Overseer" })
              return
            end
            require("overseer").run_action(tasks[1], "restart")
          end,
          desc = "Re-run last task",
        }
        maps.n["<Leader>rt"] = { "<Cmd>OverseerToggle<CR>", desc = "Toggle task list" }
        maps.n["<Leader>rc"] = { "<Cmd>OverseerShell<CR>", desc = "Run shell command" }
        maps.n["<Leader>ra"] = { "<Cmd>OverseerTaskAction<CR>", desc = "Task action (stop, restart, ...)" }
        maps.n["<Leader>rq"] = { "<Cmd>OverseerQuickAction open output<CR>", desc = "Open last task output" }
      end,
    },
  },
}
