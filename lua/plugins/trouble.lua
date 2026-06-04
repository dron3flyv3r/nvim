return {
    {
        "folke/trouble.nvim",
        dependencies = { "nvim-tree/nvim-web-devicons" },
        cmd = "Trouble",
        keys = {
            { "<leader>xx", "<cmd>Trouble diagnostics toggle<CR>", desc = "Diagnostics" },
            { "<leader>xX", "<cmd>Trouble diagnostics toggle filter.buf=0<CR>", desc = "Buffer diagnostics" },
            { "<leader>cs", "<cmd>Trouble symbols toggle focus=false<CR>", desc = "Symbols" },
            { "<leader>cl", "<cmd>Trouble lsp toggle focus=false win.position=right<CR>", desc = "LSP definitions/references" },
            { "<leader>xq", "<cmd>Trouble qflist toggle<CR>", desc = "Quickfix list" },
        },
        opts = {},
    },
}