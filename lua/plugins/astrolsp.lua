---@param source string A `Snacks.picker` source name.
---@param opts? table Passed to the picker, plus our own `hint`.
---@return fun()
local function pick(source, opts)
  opts = vim.deepcopy(opts or {})
  local hint = opts.hint
  opts.hint = nil
  return function()
    -- `vim.lsp.status()` is the same progress text the statusline shows, and is
    -- the empty string when every server is idle.
    if hint then
      local progress = vim.lsp.status()
      if progress ~= "" then
        vim.notify(
          "A language server is still working, so this list may be incomplete:\n" .. progress,
          vim.log.levels.INFO,
          { title = "LSP" }
        )
      end
    end
    require("snacks").picker[source](opts)
  end
end

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

    autocmds = {},

    mappings = {
      n = {
        K = {
          function() require("user.hover").open() end,
          desc = "Documentation for current symbol",
          cond = "textDocument/hover",
        },
        gd = {
          pick "lsp_definitions",
          desc = "Definition of current symbol",
          cond = "textDocument/definition",
        },
        gD = {
          pick "lsp_declarations",
          desc = "Declaration of current symbol",
          cond = "textDocument/declaration",
        },
        gy = {
          pick "lsp_type_definitions",
          desc = "Definition of current type",
          cond = "textDocument/typeDefinition",
        },
        gO = {
          pick "lsp_symbols",
          desc = "Symbols in this file",
          cond = "textDocument/documentSymbol",
        },

        ["<Leader>lR"] = {
          pick("lsp_references", { auto_confirm = false, hint = true }),
          desc = "References of current symbol",
          cond = "textDocument/references",
        },
        grr = {
          pick("lsp_references", { auto_confirm = false, hint = true }),
          desc = "References of current symbol",
          cond = "textDocument/references",
        },
        gri = {
          pick("lsp_implementations", { hint = true }),
          desc = "Implementations of current symbol",
          cond = "textDocument/implementation",
        },
        ["<Leader>li"] = {
          pick("lsp_implementations", { hint = true }),
          desc = "Implementations of current symbol",
          cond = "textDocument/implementation",
        },

        ["<Leader>lk"] = {
          pick("lsp_incoming_calls", { hint = true }),
          desc = "Incoming calls (who calls this)",
          cond = "textDocument/prepareCallHierarchy",
        },
        ["<Leader>lj"] = {
          pick("lsp_outgoing_calls", { hint = true }),
          desc = "Outgoing calls (what this calls)",
          cond = "textDocument/prepareCallHierarchy",
        },

        -- Workspace symbols. The default prompts for a string through
        -- `vim.ui.input` FIRST and only then queries -- so a typo costs you the
        -- whole round trip. The picker queries live as you type instead.
        ["<Leader>lG"] = {
          pick "lsp_workspace_symbols",
          desc = "Search workspace symbols",
          cond = "workspace/symbol",
        },
        ["<Leader>uF"] = {
          function()
            require("astrolsp.toggles").autoformat()
            for _, buf in ipairs(vim.api.nvim_list_bufs()) do
              if vim.api.nvim_buf_is_valid(buf) then vim.b[buf].autoformat = nil end
            end
          end,
          desc = "Toggle autoformatting (global)",
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
