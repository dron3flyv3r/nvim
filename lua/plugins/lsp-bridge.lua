-- Wiring for `user.compat.lsp_bridge`, which is where the explanation lives:
-- AstroNvim v5 talks to mason-lspconfig v1, the installed plugin is v2, and the
-- result was that AstroLSP never saw a single Mason-installed server.
---@type LazySpec
return {
  {
    "mason-org/mason-lspconfig.nvim",
    optional = true,
    opts = { automatic_enable = false },
  },

  {
    "AstroNvim/astrolsp",
    ---@type AstroLSPOpts
    opts = {
      native_lsp_config = true,

      handlers = {
        -- WITH THE BRIDGE IN PLACE, THESE FINALLY MEAN SOMETHING. Each one is a
        -- second tool doing a job something else already does -- see
        -- `python-lsp.lua` and `astrolsp.lua` for the general argument.

        stylua = false,
      },
    },
  },

  {
    "AstroNvim/astrocore",
    ---@param opts AstroCoreOpts
    opts = function(_, opts)
      local autocmds = opts.autocmds or {}
      autocmds.astrolsp_mason_bridge = {
        {
          event = "User",
          pattern = "AstroLspSetup",
          desc = "Hand Mason's language servers to AstroLSP (mason-lspconfig v2 shim)",
          once = true,
          callback = function() require("user.compat.lsp_bridge").setup() end,
        },
      }
      opts.autocmds = autocmds
    end,
  },
}
