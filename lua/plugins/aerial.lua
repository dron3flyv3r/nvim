return {
    {
        "stevearc/aerial.nvim",
        cmd = "AerialToggle",
        keys = {
            { "<leader>a", "<cmd>AerialToggle right<CR>", desc = "Toggle code outline" },
        },
        opts = {
            backends = { "lsp", "treesitter", "markdown", "man" },
            layout = {
                placement = "edge",
                default_direction = "right",
            },
            show_guides = true,
        },
    },
}