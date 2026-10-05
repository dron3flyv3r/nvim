local M = {}

---@param name string
---@param missing string
local function tool(name, missing)
  local path = vim.fn.exepath(name)
  if path ~= "" then return vim.health.ok(("%s: %s"):format(name, path)) end
  vim.health.warn(("%s is not on PATH"):format(name), { missing })
end

function M.check()
  vim.health.start "Python"
  local lsp = require "lang.python.lsp"
  local venv = require "lang.python.venv"

  local checker = lsp.checker()
  if checker then
    vim.health.ok(("type checker: %s"):format(vim.fn.exepath(checker .. "-langserver")))
  else
    vim.health.warn("no basedpyright or pyright", { "Run :MasonInstall basedpyright, then restart." })
  end
  tool("ruff", "No linting or import sorting. Run :MasonInstall ruff, then restart.")
  tool("uv", "uv projects cannot be synced, and .venv cannot be created from the editor.")

  local inherited = venv.inherited()
  if inherited then
    vim.health.info(("$VIRTUAL_ENV was set by the shell (%s); .venv directories are not followed"):format(inherited))
  else
    local active = venv.active()
    vim.health.info(("active environment: %s"):format(active and vim.fn.fnamemodify(active, ":~") or "none"))
  end

  local debugpy = require "lang.python.debugpy"
  local adapter = debugpy.adapter(venv.python(vim.fn.getcwd()))
  if adapter then
    vim.health.ok(("debugpy: %s"):format(table.concat(vim.list_extend({ adapter.command }, adapter.args or {}), " ")))
  else
    vim.health.warn("no debugpy", { debugpy.HINT })
  end
end

return M
