return {
  {
    "L3MON4D3/LuaSnip",
    version = "v2.*",
    build = "make install_jsregexp",

    dependencies = {
      "rafamadriz/friendly-snippets",
    },

    config = function()
      local luasnip = require "luasnip"

      require("luasnip.loaders.from_vscode").lazy_load()

      require("luasnip.loaders.from_vscode").lazy_load {
        paths = {
          vim.fn.stdpath "config" .. "/snippets",
        },
      }

      luasnip.config.setup {
        history = true,
        updateevents = "TextChanged,TextChangedI",
      }
    end,
  },

  {
    "saadparwaiz1/cmp_luasnip",
  },
}
