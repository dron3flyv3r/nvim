local M = {}

M.HINT = "No debugpy. Run :MasonInstall debugpy, or `uv add --dev debugpy` in the project."

---@type table<string, boolean>
local importable = {}

---@param python string
---@return boolean
local function has_debugpy(python)
  if importable[python] == nil then
    local ok, result = pcall(function() return vim.system({ python, "-c", "import debugpy" }):wait(3000) end)
    importable[python] = ok and result.code == 0
  end
  return importable[python]
end

---@param python string|nil the debuggee's interpreter, tried last
---@return table|nil
function M.adapter(python)
  local exe = vim.fn.exepath "debugpy-adapter"
  if exe ~= "" then return { type = "executable", command = exe } end

  local mason =
    vim.fs.joinpath(vim.fn.stdpath "data" --[[@as string]], "mason", "packages", "debugpy", "venv", "bin", "python")
  for _, candidate in ipairs { mason, python or "" } do
    if candidate ~= "" and vim.fn.executable(candidate) == 1 and has_debugpy(candidate) then
      return { type = "executable", command = candidate, args = { "-m", "debugpy.adapter" } }
    end
  end
end

---@param callback fun(adapter: table)
---@param config table
function M.resolve(callback, config)
  local python = type(config.python) == "table" and config.python[1] or config.python
  local adapter = M.adapter(python)
  if not adapter then return vim.notify(M.HINT, vim.log.levels.ERROR, { title = "Python" }) end
  callback(adapter)
end

---@param python string
---@return boolean|string
function M.ready(python) return M.adapter(python) ~= nil or M.HINT end

return M
