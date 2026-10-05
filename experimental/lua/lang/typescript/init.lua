local debug = require "lang.typescript.debug"
local lsp = require "lang.typescript.lsp"

---@type lang.Module
return {
  ft = lsp.FILETYPES,

  -- Absent when no server is installed: `vim.lsp.enable` on a missing `cmd`
  -- warns at every matching FileType from then on.
  lsp = lsp.config(),

  dap = {
    adapters = { ["pwa-node"] = debug.resolve, ["pwa-chrome"] = debug.resolve },
  },

  actions = require "lang.typescript.actions",
}
