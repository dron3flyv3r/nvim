return {
    {
        "akinsho/bufferline.nvim",
        version = "*",
        dependencies = {
            "nvim-tree/nvim-web-devicons",
        },
        event = "VeryLazy",
        opts = {
            options = {
                mode = "buffers",
                separator_style = "slant",
                always_show_bufferline = true,
                show_buffer_close_icons = true,
                show_close_icon = false,
                diagnostics = "nvim_lsp",
                offsets = {
                    {
                        filetype = "neo-tree",
                        text = "File Explorer",
                        text_align = "center",
                        separator = true,
                    },
                },
            },
        },
        keys = {
            { "<Tab>", "<cmd>BufferLineCycleNext<CR>", desc = "Next buffer" },
            { "<S-Tab>", "<cmd>BufferLineCyclePrev<CR>", desc = "Previous buffer" },
            { "<leader>bd", "<cmd>bdelete<CR>", desc = "Close buffer" },
            { "<leader>bp", "<cmd>BufferLinePick<CR>", desc = "Pick buffer" },
            { "<leader>bl", "<cmd>BufferLineCloseRight<CR>", desc = "Close buffers right" },
            { "<leader>bh", "<cmd>BufferLineCloseLeft<CR>", desc = "Close buffers left" },
        },
    },
}