return {
    {
        "mason-org/mason.nvim",
        opts = {},
    },

    {
        "mason-org/mason-lspconfig.nvim",
        dependencies = {
            "mason-org/mason.nvim",
            "neovim/nvim-lspconfig",
        },
        opts = {
            ensure_installed = {
                "lua_ls",
                "pyright",
                "ruff",
                "clangd",
                "ts_ls",
            },
        },
    },

    {
        "neovim/nvim-lspconfig",
        dependencies = {
            "mason-org/mason.nvim",
            "mason-org/mason-lspconfig.nvim",
            "hrsh7th/cmp-nvim-lsp",
        },
        config = function()
            local capabilities = require("cmp_nvim_lsp").default_capabilities()

            vim.lsp.config("lua_ls", {
                capabilities = capabilities,
                settings = {
                    Lua = {
                        diagnostics = {
                            globals = { "vim" },
                        },
                    },
                },
            })

            vim.lsp.config("pyright", {
                capabilities = capabilities,
            })

            vim.lsp.config("clangd", {
                capabilities = capabilities,
            })

            vim.lsp.config("ts_ls", {
                capabilities = capabilities,
            })

            vim.lsp.config("ruff", {
                capabilities = capabilities,
            })

            vim.lsp.enable("ruff")

            local servers = {
                "lua_ls",
                "pyright",
                "clangd",
                "ts_ls",
            }

            for _, server in ipairs(servers) do
                vim.lsp.enable(server)
            end

            vim.keymap.set("n", "gd", vim.lsp.buf.definition, { desc = "Go to definition" })
            vim.keymap.set("n", "gD", vim.lsp.buf.declaration, { desc = "Go to declaration" })
            vim.keymap.set("n", "gi", vim.lsp.buf.implementation, { desc = "Go to implementation" })
            vim.keymap.set("n", "gr", vim.lsp.buf.references, { desc = "Go to references" })
            vim.keymap.set("n", "gt", vim.lsp.buf.type_definition, { desc = "Go to type definition" })

            vim.keymap.set("n", "<A-Left>", "<C-o>", { desc = "Jump back" })
            vim.keymap.set("n", "<A-Right>", "<C-i>", { desc = "Jump forward" })

            vim.keymap.set("n", "<leader>rn", vim.lsp.buf.rename, { desc = "Rename symbol" })
            vim.keymap.set("n", "<leader>ca", vim.lsp.buf.code_action, { desc = "Code action" })
            vim.keymap.set("n", "K", vim.lsp.buf.hover, { desc = "Hover docs" })
        end,
    },
}
