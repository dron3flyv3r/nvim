return {
    {
        "nvim-neo-tree/neo-tree.nvim",
        branch = "v3.x",
        event = "VimEnter",
        dependencies = {
            "nvim-lua/plenary.nvim",
            "MunifTanjim/nui.nvim",
            "nvim-tree/nvim-web-devicons",
        },
        keys = {
            { "<leader>e", "<cmd>Neotree toggle left<CR>", desc = "Toggle file tree" },
            { "<leader>o", "<cmd>Neotree focus left<CR>", desc = "Focus file tree" },
        },
        opts = {
            close_if_last_window = false,
            popup_border_style = "rounded",
            enable_git_status = true,
            enable_diagnostics = true,

            filesystem = {
                filtered_items = {
                    visible = true,
                    hide_dotfiles = false,
                    hide_gitignored = false,
                },
                follow_current_file = {
                    enabled = true,
                },
                use_libuv_file_watcher = true,
            },

            window = {
                position = "left",
                width = 32,
            },
        },
        config = function(_, opts)
            require("neo-tree").setup(opts)

            if vim.fn.argc() == 1 then
                local arg = vim.fn.argv(0)

                if vim.fn.isdirectory(arg) == 1 then
                    vim.cmd("Neotree left")
                end
            end
        end,
    },
}