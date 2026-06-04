return {
    {
        "akinsho/toggleterm.nvim",
        version = "*",
        keys = {
            { "<leader>tt", "<cmd>ToggleTerm<CR>", desc = "Toggle terminal" },
        },
        opts = {
            size = 20,
            open_mapping = [[<C-\>]],
            hide_numbers = true,
            shade_terminals = true,
            start_in_insert = true,
            insert_mappings = true,
            terminal_mappings = true,
            persist_size = true,
            direction = "horizontal",
            close_on_exit = false,
            shell = vim.o.shell,
        },
    },
}