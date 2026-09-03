---@param pattern string A Lua pattern matched against the code action title
---@return function
local function refactoring(pattern)
  return function()
    vim.lsp.buf.code_action {
      -- `apply` skips the picker when exactly one action matches, which is the
      -- whole point of these keys. When two match it still asks, which is the
      -- right fallback.
      apply = true,
      filter = function(action) return (action.title or ""):find(pattern) ~= nil end,
    }
  end
end

---@param client vim.lsp.Client
---@return boolean
local function clangd(client) return client.name == "clangd" end

---@type LazySpec
return {
  {
    "AstroNvim/astrolsp",
    ---@type AstroLSPOpts
    opts = {
      mappings = {
        n = {
          ["<Leader>lc"] = { desc = "Refactor", cond = clangd },

          ["<Leader>lco"] = {
            refactoring "body to out%-of%-line",
            desc = "Move function body to the .cpp",
            cond = clangd,
          },
          ["<Leader>lci"] = {
            refactoring "body to declaration",
            desc = "Move function body to the header",
            cond = clangd,
          },

          ["<Leader>lcm"] = {
            refactoring "^Declare implicit",
            desc = "Declare implicit copy/move members",
            cond = clangd,
          },
          ["<Leader>lcc"] = { refactoring "^Define constructor", desc = "Define constructor", cond = clangd },

          -- Cursor on the `switch`: adds a `case` for every enumerator not yet
          -- handled. The one refactoring here that is genuinely faster than a
          -- human every single time.
          ["<Leader>lcs"] = {
            refactoring "^Populate switch",
            desc = "Populate switch with missing cases",
            cond = clangd,
          },

          -- Cursor on `using namespace foo;`: deletes it and qualifies every
          -- name that depended on it. The cleanup for a header that acquired
          -- one by accident.
          ["<Leader>lcu"] = {
            refactoring "Remove using namespace",
            desc = "Remove using namespace, qualify names",
            cond = clangd,
          },

          -- `enum E` -> `enum class E`, qualifying the enumerators at every
          -- use site.
          ["<Leader>lce"] = { refactoring "scoped enum", desc = "Convert to scoped enum", cond = clangd },

          ["<Leader>lr"] = {
            function() return ":IncRename " .. vim.fn.expand "<cword>" end,
            expr = true,
            desc = "Rename symbol across the project (live preview)",
            cond = "textDocument/rename",
          },

          ["<Leader>la"] = {
            function() require("user.quick_fix").code_action(require("actions-preview").code_actions)() end,
            desc = "LSP code action (preview diff)",
            cond = "textDocument/codeAction",
          },
        },

        x = {
          ["<Leader>lc"] = { desc = "Refactor", cond = clangd },

          ["<Leader>lcf"] = {
            refactoring "^Extract to function",
            desc = "Extract selection to function",
            cond = clangd,
          },
          ["<Leader>lcv"] = {
            refactoring "^Extract subexpression",
            desc = "Extract selection to variable",
            cond = clangd,
          },

          ["<Leader>la"] = {
            function() require("actions-preview").code_actions() end,
            desc = "LSP code action (preview diff)",
            cond = "textDocument/codeAction",
          },
        },
      },
    },
  },

  {
    "aznhe21/actions-preview.nvim",
    -- Loaded by the `<Leader>la` mappings above, which are set on LspAttach.
    lazy = true,
    opts = {
      backend = { "snacks", "nui" },
    },
  },

  {
    -- `:IncRename`, driving `textDocument/rename` through `'inccommand'`.
    "smjonas/inc-rename.nvim",
    cmd = "IncRename",
    opts = {},
    dependencies = {
      {
        "AstroNvim/astrocore",
        ---@type AstroCoreOpts
        opts = {
          options = {
            opt = {
              inccommand = "split",
            },
          },
        },
      },
    },
  },
}
