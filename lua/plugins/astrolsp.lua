-- AstroLSP: how language servers attach, format, and what they show.
-- Configuration documentation: `:h astrolsp`
--
-- Per-language tuning lives next door -- see `python-lsp.lua`. This file is the
-- behaviour that should be true of every server.
---@type LazySpec
return {
  "AstroNvim/astrolsp",
  ---@type AstroLSPOpts
  opts = {
    features = {
      codelens = true,

      -- Inlay hints: the greyed-in `param:` labels and inferred types that VS
      -- Code shows between your own tokens. basedpyright and clangd both
      -- provide them. `<Leader>uH` toggles them off when a line gets busy.
      inlay_hints = true,

      semantic_tokens = true,
    },

    -- Format on save, for every filetype that has a formatter attached:
    -- ruff for Python, clangd (clang-format) for C/C++, stylua for Lua.
    formatting = {
      format_on_save = {
        enabled = true,
        allow_filetypes = {}, -- empty = all filetypes
        ignore_filetypes = {},
      },
      disabled = {
        -- lua_ls can format, but stylua (via none-ls) matches `.stylua.toml`,
        -- which is what this config is actually written to.
        "lua_ls",
      },
      timeout_ms = 1000,
    },

    -- Servers installed outside Mason that should still be set up.
    servers = {},

    ---@diagnostic disable: missing-fields
    config = {},

    handlers = {},

    autocmds = {
      lsp_codelens_refresh = {
        cond = "textDocument/codeLens",
        {
          event = { "InsertLeave", "BufEnter" },
          desc = "Refresh codelens (buffer)",
          callback = function(args)
            if require("astrolsp").config.features.codelens then vim.lsp.codelens.refresh { bufnr = args.buf } end
          end,
        },
      },
    },

    mappings = {
      n = {
        gD = {
          function() vim.lsp.buf.declaration() end,
          desc = "Declaration of current symbol",
          cond = "textDocument/declaration",
        },
        ["<Leader>uY"] = {
          function() require("astrolsp.toggles").buffer_semantic_tokens() end,
          desc = "Toggle LSP semantic highlight (buffer)",
          cond = function(client)
            -- `client:supports_method` (method call) -- the dot form is
            -- deprecated as of Neovim 0.11 and warns on every attach.
            return client:supports_method "textDocument/semanticTokens/full" and vim.lsp.semantic_tokens ~= nil
          end,
        },
      },
    },
  },
}
