local M = {}

local LOCKFILES = {
  { "pnpm-lock.yaml", "pnpm" },
  { "yarn.lock", "yarn" },
  { "bun.lock", "bun" },
  { "bun.lockb", "bun" },
  { "package-lock.json", "npm" },
}

---@class typescript.Package
---@field root string the directory holding package.json
---@field name string
---@field manager "npm"|"pnpm"|"yarn"|"bun"
---@field scripts table<string, string>
---@field deps table<string, true>

---@param path string
---@return table|nil
local function read_json(path)
  local file = io.open(path, "r")
  if not file then return nil end
  local text = file:read "*a"
  file:close()
  local ok, decoded = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
  return ok and type(decoded) == "table" and decoded or nil
end

---@param root string
---@param json table
---@return "npm"|"pnpm"|"yarn"|"bun"
local function manager_of(root, json)
  local declared = type(json.packageManager) == "string" and json.packageManager:match "^(%a+)@"
  if declared and vim.list_contains({ "npm", "pnpm", "yarn", "bun" }, declared) then return declared end
  local dir = root
  while dir do
    for _, lock in ipairs(LOCKFILES) do
      if vim.uv.fs_stat(vim.fs.joinpath(dir, lock[1])) then return lock[2] end
    end
    local parent = vim.fs.dirname(dir)
    dir = parent ~= dir and parent or nil
  end
  return "npm"
end

---@param path string a file or directory inside the package
---@return typescript.Package|nil
function M.find(path)
  if path == "" then return nil end
  local root = vim.fs.root(path, "package.json")
  if not root then return nil end
  local json = read_json(vim.fs.joinpath(root, "package.json")) or {}
  local deps = {}
  for _, field in ipairs { "dependencies", "devDependencies", "peerDependencies" } do
    for name in pairs(type(json[field]) == "table" and json[field] or {}) do
      deps[name] = true
    end
  end
  return {
    root = root,
    name = type(json.name) == "string" and json.name or vim.fs.basename(root),
    manager = manager_of(root, json),
    scripts = type(json.scripts) == "table" and json.scripts or {},
    deps = deps,
  }
end

---@param pkg typescript.Package
---@param name string
---@return string|nil
function M.bin(pkg, name)
  local dir = pkg.root
  while dir do
    local candidate = vim.fs.joinpath(dir, "node_modules", ".bin", name)
    if vim.fn.executable(candidate) == 1 then return candidate end
    local parent = vim.fs.dirname(dir)
    dir = parent ~= dir and parent or nil
  end
end

---@param pkg typescript.Package
---@return boolean
function M.installed(pkg) return vim.uv.fs_stat(vim.fs.joinpath(pkg.root, "node_modules")) ~= nil end

---@type vim.Version|false|nil
local node_version

---@return vim.Version|nil
function M.node_version()
  if node_version == nil then
    local ok, result = pcall(function() return vim.system({ "node", "--version" }, { text = true }):wait(2000) end)
    node_version = ok and result.code == 0 and vim.version.parse(result.stdout) or false
  end
  return node_version or nil
end

---@return boolean
function M.node_strips_types()
  local version = M.node_version()
  return version ~= nil and vim.version.ge(version, { 23, 6, 0 })
end

return M
