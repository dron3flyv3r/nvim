local venv = require "lang.python.venv"

local M = {}

local ROOT_MARKERS = { "pyproject.toml", "setup.py", "setup.cfg", "requirements.txt", "pyrightconfig.json", ".git" }

local RUFF_OWNS = {
  reportUnusedImport = "none",
  reportUnusedVariable = "none",
  reportUnusedFunction = "none",
  reportUnusedClass = "none",
  reportUnusedExpression = "none",
}

---@return "basedpyright"|"pyright"|nil
function M.checker()
  for _, name in ipairs { "basedpyright", "pyright" } do
    if vim.fn.executable(name .. "-langserver") == 1 then return name end
  end
end

---@return boolean
function M.has_ruff() return vim.fn.executable "ruff" == 1 end

---@param _ lsp.InitializeParams
---@param config vim.lsp.ClientConfig
local function point_at_interpreter(_, config)
  config.settings.python = config.settings.python or {}
  config.settings.python.pythonPath = venv.python(config.root_dir)
end

---@param name "basedpyright"|"pyright"
---@return vim.lsp.Config
local function checker_config(name)
  local analysis = {
    autoSearchPaths = true,
    useLibraryCodeForTypes = true,
    diagnosticMode = "openFilesOnly",
    diagnosticSeverityOverrides = M.has_ruff() and RUFF_OWNS or nil,
    inlayHints = { variableTypes = true, functionReturnTypes = true, callArgumentNames = true },
  }
  return {
    cmd = { name .. "-langserver", "--stdio" },
    root_markers = ROOT_MARKERS,
    before_init = point_at_interpreter,
    settings = {
      -- basedpyright reads its own section and pyright reads `python.analysis`;
      -- the fork that is not running ignores the other.
      basedpyright = { analysis = analysis, disableOrganizeImports = M.has_ruff() },
      pyright = { disableOrganizeImports = M.has_ruff() },
      python = { analysis = analysis },
    },
  }
end

---@return table<string, vim.lsp.Config>|nil
function M.config()
  local servers = {}
  local checker = M.checker()
  if checker then servers[checker] = checker_config(checker) end
  if M.has_ruff() then
    servers.ruff = {
      cmd = { "ruff", "server" },
      root_markers = { "ruff.toml", ".ruff.toml", "pyproject.toml", ".git" },
      on_attach = function(client) client.server_capabilities.hoverProvider = false end,
    }
  end
  return next(servers) and servers or nil
end

---@return string[]
function M.names()
  local names = {}
  if M.checker() then names[#names + 1] = M.checker() end
  if M.has_ruff() then names[#names + 1] = "ruff" end
  return names
end

return M
