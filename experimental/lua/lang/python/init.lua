require("lang.python.venv").setup()

---@type lang.Module
return {
  ft = { "python" },

  -- Absent when no server is installed: `vim.lsp.enable` on a missing `cmd`
  -- warns at every matching FileType from then on.
  lsp = require("lang.python.lsp").config(),

  dap = {
    adapters = { python = require("lang.python.debugpy").resolve },
  },

  actions = require "lang.python.actions",
}
