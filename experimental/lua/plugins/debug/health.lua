local M = {}

function M.check()
  local health = vim.health
  health.start "debugger"

  -- Requiring it loads it: lazy's loader answers a require for a plugin module,
  -- so this reports installation, not whether the debugger was already up.
  if not pcall(require, "dap") then return health.error "nvim-dap is not installed" end

  local adapters = require "plugins.debug.adapters"
  local codelldb = adapters.codelldb()
  if codelldb then
    health.ok(("codelldb: %s"):format(codelldb.executable.command))
  else
    health.warn("no codelldb", { adapters.install_hint() })
  end

  local names = adapters.names()
  if #names > 0 then
    health.info(("registered adapters: %s"):format(table.concat(names, ", ")))
  else
    health.warn "no adapters are registered"
  end

  if pcall(require, "dapui") then
    health.ok "nvim-dap-ui is available"
  else
    health.error "nvim-dap-ui is missing -- the panel and the value floats need it"
  end

  local breakpoints = require "plugins.debug.breakpoints"
  local store = breakpoints.store_path(vim.fn.getcwd())
  health.info(("breakpoints: %d, store %s"):format(breakpoints.count(), vim.fn.fnamemodify(store, ":~")))
end

return M
