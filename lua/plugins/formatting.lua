return {
    {
        "stevearc/conform.nvim",
        event = { "BufWritePre" },
        cmd = { "ConformInfo" },
        keys = {
            {
                "<leader>f",
                function()
                    require("conform").format({
                        async = true,
                        lsp_fallback = true,
                    })
                end,
                desc = "Format file",
            },
        },
        opts = {
            formatters_by_ft = {
                python = { "ruff_format" },
                lua = { "stylua" },
                cpp = { "clang_format" },
                c = { "clang_format" },
                javascript = { "prettier" },
                typescript = { "prettier" },
                json = { "prettier" },
                yaml = { "prettier" },
            },
            format_on_save = {
                timeout_ms = 1000,
                lsp_fallback = true,
            },
        },
    },
}