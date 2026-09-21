---@type LazySpec
return {
  "mason-org/mason.nvim",
  version = "^2.0.0",
  cmd = { "Mason", "MasonInstall", "MasonUninstall", "MasonUninstallAll", "MasonUpdate", "MasonLog" },
  ---@type MasonSettings
  opts = {
    -- init.lua prepends the same directory before the lang layer probes for
    -- binaries; letting mason do it again only duplicates the entry.
    PATH = "skip",
    ui = {
      border = "rounded",
      backdrop = 100,
    },
  },
}
