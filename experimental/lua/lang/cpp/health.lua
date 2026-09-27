local M = {}

---@param name string
---@param missing string
local function tool(name, missing)
  local path = vim.fn.exepath(name)
  if path ~= "" then return vim.health.ok(("%s: %s"):format(name, path)) end
  vim.health.warn(("%s is not on PATH"):format(name), { missing })
end

function M.check()
  vim.health.start "C/C++"
  tool("clangd", "No language server for C/C++. Install clang or run :MasonInstall clangd.")
  tool("cmake", "CMake projects cannot be configured or built.")
  tool("ninja", "CMake falls back to its default generator, which is slower.")
  tool("ctest", "CMake projects cannot run their tests.")
  tool("make", "Makefile projects cannot be built.")

  local compilers = vim.tbl_filter(function(name) return vim.fn.executable(name) == 1 end, { "g++", "clang++", "gcc" })
  if #compilers > 0 then
    vim.health.ok("single-file compilers: " .. table.concat(compilers, ", "))
  else
    vim.health.warn "no gcc, g++ or clang: a file outside a project cannot be compiled"
  end

  local adapters = require "plugins.debug.adapters"
  if adapters.codelldb() then
    vim.health.ok "codelldb found for debugging"
  else
    vim.health.warn("no codelldb", { adapters.install_hint() })
  end
end

return M
