local M = {}

--- Servers already handed to AstroLSP. `lsp_setup` is idempotent, but Mason
--- fires `package:install:success` per install and there is no reason to redo
--- the work.
---@type table<string, true>
local configured = {}

---@return string[]
local function installed_servers()
  local registry_ok, registry = pcall(require, "mason-registry")
  local mappings_ok, mappings = pcall(require, "mason-lspconfig.mappings")
  if not (registry_ok and mappings_ok) then return {} end

  local package_to_server = mappings.get_mason_map().package_to_lspconfig
  local servers = {}
  for _, package in ipairs(registry.get_installed_package_names()) do
    local server = package_to_server[package]
    if server then servers[server] = true end
  end
  return vim.tbl_keys(servers)
end

--- Hand every installed server to AstroLSP. Safe to call more than once.
function M.setup()
  local astrolsp_ok, astrolsp = pcall(require, "astrolsp")
  if not astrolsp_ok then return end

  local started = false
  for _, server in ipairs(installed_servers()) do
    if not configured[server] then
      configured[server] = true

      if #vim.api.nvim_get_runtime_file("lsp/" .. server .. ".lua", false) > 0 then
        local override_ok, override = pcall(require, "mason-lspconfig.lsp." .. server)
        if override_ok then vim.lsp.config(server, override) end

        astrolsp.lsp_setup(server)
        started = true
      end
    end
  end

  if not started then return end

  vim.schedule(function() pcall(vim.cmd.doautoall, "nvim.lsp.enable FileType") end)
end

return M
