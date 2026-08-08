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
      -- Servers that may NOT format, because none-ls already runs the same tool
      -- and two formatters on one buffer is how you get a fight on every save.
      disabled = {
        -- stylua, via none-ls, and it reads `.stylua.toml`.
        "lua_ls",
        -- clang-format, via none-ls. clangd embeds clang-format and would
        -- happily do it too -- same tool, same `.clang-format` file, so the
        -- result is identical and the second pass is pure waste.
        "clangd",
      },
      timeout_ms = 1000,
    },

    -- Servers installed outside Mason that should still be set up.
    servers = {},

    ---@diagnostic disable: missing-fields
    config = {},

    handlers = {},

    -- NOTE: the AstroNvim template ships an `lsp_codelens_refresh` autocmd here
    -- that re-runs codelens on InsertLeave/BufEnter. It is gone on purpose:
    -- `features.codelens` above already refreshes on attach, and on Neovim 0.12
    -- codelens is managed by the `vim.lsp._capability` framework, which handles
    -- its own refreshing. The autocmd was both redundant and a second call site
    -- for `vim.lsp.codelens.refresh()`, which is deprecated in favour of
    -- `vim.lsp.codelens.enable()` and warns on startup.
    autocmds = {},

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
