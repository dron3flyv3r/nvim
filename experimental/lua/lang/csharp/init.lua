---@type lang.Module
return {
  ft = { "cs" },

  -- Absent when the server is not installed: `vim.lsp.enable` on a missing
  -- `cmd` warns at every matching FileType from then on.
  lsp = require("lang.csharp.roslyn").config(),

  actions = require "lang.csharp.actions",
}
