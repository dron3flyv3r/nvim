---@type lang.Module
return {
  ft = { "cs" },

  -- Absent when the server is not installed: `vim.lsp.enable` on a missing
  -- `cmd` warns at every matching FileType from then on.
  lsp = require("lang.csharp.roslyn").config(),

  plugins = {
    { "echasnovski/mini.pairs", opts = { brace_own_line = { cs = true } } },
    {
      url = "https://gitlab.com/schrieveslaach/sonarlint.nvim",
      optional = true,
      opts = { languages = { csharp = require "lang.csharp.analysis" } },
    },
  },

  actions = require "lang.csharp.actions",
}
