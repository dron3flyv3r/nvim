local M = {}

local STORE = vim.fs.normalize "~/.local/share/nvim-dap/codelldb/extension"

---@return string|nil
local function find_codelldb()
  -- `or ""` rather than the bare value: $CODELLDB is usually unset, and a nil in a
  -- table constructor truncates the list ipairs walks.
  local candidates = { vim.env.CODELLDB or "", vim.fn.exepath "codelldb", STORE .. "/adapter/codelldb" }
  for _, candidate in ipairs(candidates) do
    if candidate ~= "" and vim.fn.executable(candidate) == 1 then return candidate end
  end
end

---@return table|nil
function M.codelldb()
  local command = find_codelldb()
  if not command then return nil end

  local args = { "--port", "${port}" }
  -- Only the vsix layout ships liblldb; a distro codelldb finds the system one
  -- itself and passing a path that is not there makes it exit immediately.
  local liblldb = vim.fs.joinpath(vim.fs.dirname(vim.fs.dirname(command)), "lldb", "lib", "liblldb.so")
  if vim.uv.fs_stat(liblldb) then vim.list_extend(args, { "--liblldb", liblldb }) end

  return { type = "server", port = "${port}", executable = { command = command, args = args } }
end

---@return string
function M.install_hint()
  return "No codelldb found. Install it once with `just install-codelldb`,\n"
    .. "or point $CODELLDB at an existing adapter binary."
end

---@param spec lang.DapSpec
---@param dap table
local function apply(spec, dap)
  for name, adapter in pairs(spec.dap.adapters or {}) do
    dap.adapters[name] = adapter
  end

  local configurations = spec.dap.configurations
  if type(configurations) == "function" then
    -- A named provider, so re-applying replaces it rather than stacking, and so
    -- a language is only asked about buffers it claims.
    dap.providers.configs["lang." .. spec.name] = function(bufnr)
      if not vim.tbl_contains(spec.ft, vim.bo[bufnr].filetype) then return {} end
      return configurations(bufnr) or {}
    end
  elseif type(configurations) == "table" then
    for _, ft in ipairs(spec.ft) do
      dap.configurations[ft] = vim.list_extend(vim.deepcopy(configurations), dap.configurations[ft] or {})
    end
  end
end

function M.setup()
  local dap = require "dap"

  local codelldb = M.codelldb()
  if codelldb then dap.adapters.codelldb = codelldb end

  for _, spec in ipairs(require("core.lang").dap_specs()) do
    local ok, err = pcall(apply, spec, dap)
    if not ok then
      vim.notify(("lang/%s: bad dap spec: %s"):format(spec.name, err), vim.log.levels.ERROR, { title = "Debug" })
    end
  end
end

---@return string[]
function M.names()
  local names = vim.tbl_keys(require("dap").adapters)
  table.sort(names)
  return names
end

return M
