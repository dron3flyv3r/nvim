return {
    {
        "stevearc/overseer.nvim",
        cmd = {
            "OverseerRun",
            "OverseerToggle",
            "OverseerQuickAction",
            "OverseerRestartLast",
        },
        keys = {
            { "<leader>rr", "<cmd>OverseerRun<CR>", desc = "Run task" },
            { "<leader>rt", "<cmd>OverseerToggle<CR>", desc = "Toggle task list" },
            { "<leader>ra", "<cmd>OverseerQuickAction<CR>", desc = "Task action" },
            { "<leader>rl", "<cmd>OverseerRestartLast<CR>", desc = "Restart last task" },

            {
                "<leader>rd",
                function()
                    require("overseer").run_task({
                        name = "SOPA",
                        params = {
                            task = "deploy",
                        },
                    })
                end,
                desc = "SOPA deploy",
            },

            {
                "<leader>rD",
                function()
                    require("overseer").run_task({
                        name = "SOPA",
                        params = {
                            task = "deploy-force",
                        },
                    })
                end,
                desc = "SOPA force deploy",
            },
        },
        opts = {
            task_list = {
                direction = "bottom",
                min_height = 10,
                max_height = 20,
                default_detail = 1,
            },
        },
    },
}