-- Native `:checkhealth user` entrypoint for the assumptions this config owns.
local M = {}

local function executable(name, required, note)
  if vim.fn.executable(name) == 1 then
    vim.health.ok(name .. " is executable")
  elseif required then
    vim.health.error(name .. " is missing", note and { note } or nil)
  else
    vim.health.warn(name .. " is unavailable", note and { note } or nil)
  end
end

function M.check()
  vim.health.start "Core"
  vim.health.info(("Neovim %d.%d.%d"):format(vim.version().major, vim.version().minor, vim.version().patch))
  if vim.fn.has "nvim-0.12" == 1 then
    vim.health.ok "Neovim 0.12 native LSP APIs are available"
  else
    vim.health.error "This configuration currently targets Neovim 0.12+"
  end
  local ok, lazy = pcall(require, "lazy.core.config")
  if ok then
    local missing = {}
    for name, plugin in pairs(lazy.plugins) do
      if not (vim.uv or vim.loop).fs_stat(plugin.dir) then table.insert(missing, name) end
    end
    if vim.tbl_isempty(missing) then
      vim.health.ok "All locked plugins are installed"
    else
      table.sort(missing)
      vim.health.error("Missing plugins: " .. table.concat(missing, ", "), { "Run :Lazy sync" })
    end
  else
    vim.health.error "lazy.nvim configuration is unavailable"
  end

  vim.health.start "Development tools"
  executable("git", true)
  executable("rg", false, "Project search falls back to slower tools without ripgrep")
  executable("tree-sitter", false, "Required when installing parsers from source")
  executable("stylua", false, "Lua formatting will be unavailable")
  executable("ruff", false, "Python linting and formatting will be unavailable")
  executable("rust-analyzer", false, "Rust LSP support expects the system package")
  executable("clangd", false, "C/C++ language intelligence will be unavailable")
  executable("cmake", false, "CMake project actions will be unavailable")
  executable("ninja", false, "CMake is configured to generate Ninja builds")
  executable("uv", false, "Python environment and notebook bootstrap actions prefer uv")
  executable("jupytext", false, "Opening .ipynb as editable Python requires jupytext")

  vim.health.start "Context actions"
  local context_ok, context = pcall(require, "user.context")
  if not context_ok then
    vim.health.error("Context registry failed to load: " .. tostring(context))
    return
  end
  local resolved = context.resolve()
  local names = vim.tbl_map(function(provider) return provider.name end, resolved.providers)
  vim.health.ok(("Registry loaded with %d active provider(s)"):format(#names))
  if #names > 0 then vim.health.info("Current context: " .. table.concat(names, ", ")) end

  vim.health.start "Compatibility"
  vim.health.info "LSP bridge is isolated in plugins/lsp-bridge.lua and user/compat/lsp_bridge.lua"
  vim.health.info "Treesitter 0.12 compatibility is isolated in user/compat/treesitter_directives.lua"
end

return M
