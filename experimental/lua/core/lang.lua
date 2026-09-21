local M = {}

---@class lang.Dap
---@field adapters? table<string, table|fun(callback: fun(adapter: table), config: table)>
---@field configurations? table[]|fun(bufnr: integer): table[]

---@class lang.Module
---@field ft? string|string[]
---@field lsp? table<string, vim.lsp.Config>
---@field dap? lang.Dap
---@field plugins? LazySpec[]
---@field actions? core.ActionProvider

local KNOWN_KEYS = { ft = true, lsp = true, dap = true, plugins = true, actions = true }

---@type table<string, lang.Module>
M.modules = {}

local function report(message)
  vim.schedule(function() vim.notify(message, vim.log.levels.ERROR, { title = "lang" }) end)
end

local function root() return vim.fn.stdpath "config" .. "/lua/lang" end

---@return string[]
function M.discover()
  local names = {}
  local dir = root()
  if vim.fn.isdirectory(dir) == 0 then return names end
  for entry, kind in vim.fs.dir(dir) do
    if kind == "file" and entry:sub(-4) == ".lua" and entry ~= "init.lua" then
      table.insert(names, entry:sub(1, -5))
    elseif kind == "directory" and vim.uv.fs_stat(dir .. "/" .. entry .. "/init.lua") then
      table.insert(names, entry)
    end
  end
  table.sort(names)
  return names
end

---@param name string
---@param module unknown
---@return lang.Module|nil
local function validate(name, module)
  if type(module) ~= "table" then
    report(("lang/%s must return a table, got %s"):format(name, type(module)))
    return nil
  end
  for key in pairs(module) do
    if not KNOWN_KEYS[key] then
      report(("lang/%s: unknown key %q (allowed: ft, lsp, dap, plugins, actions)"):format(name, tostring(key)))
      return nil
    end
  end
  return module
end

---@return LazySpec[]
function M.specs()
  if M._specs then return M._specs end
  local specs = {}
  for _, name in ipairs(M.discover()) do
    local ok, module = pcall(require, "lang." .. name)
    if not ok then
      report(("lang/%s failed to load: %s"):format(name, module))
    else
      module = validate(name, module)
      if module then
        M.modules[name] = module
        vim.list_extend(specs, module.plugins or {})
      end
    end
  end
  M._specs = specs
  return specs
end

---@param module lang.Module
---@return string[]|nil
local function filetypes(module)
  if not module.ft then return nil end
  return type(module.ft) == "table" and module.ft or { module.ft }
end

---@class lang.DapSpec
---@field name string
---@field ft string[]
---@field dap lang.Dap

--- Collected, not applied: the debugger lives in the plugin layer and is what
--- hands these to nvim-dap.
---@return lang.DapSpec[]
function M.dap_specs()
  if not M._specs then M.specs() end
  local specs = {}
  for name, module in pairs(M.modules) do
    if module.dap then specs[#specs + 1] = { name = name, ft = filetypes(module) or {}, dap = module.dap } end
  end
  table.sort(specs, function(a, b) return a.name < b.name end)
  return specs
end

function M.setup()
  local actions = require "core.actions"
  for name, module in pairs(M.modules) do
    for server, config in pairs(module.lsp or {}) do
      if not config.filetypes then config.filetypes = filetypes(module) end
      vim.lsp.config(server, config)
      vim.lsp.enable(server)
    end
    if module.actions then
      local provider = vim.tbl_extend("keep", module.actions, { id = name, name = name })
      local ok, err = pcall(actions.register, provider)
      if not ok then report(("lang/%s: %s"):format(name, err)) end
    end
  end
end

return M
