local M = {}

local MANIFEST = "Cargo.toml"

M.errorformat = table.concat({
  [[%Eerror: %\%%(aborting %\|could not compile%\)%\@!%m]],
  [[%Eerror[E%n]: %m]],
  [[%Inote: %m]],
  [[%Wwarning: %\%%(%.%# warning%\)%\@!%m]],
  [[%C %#--> %f:%l:%c]],
  [[%E  left:%m]],
  [[%C right:%m %f:%l:%c]],
  [[%Z]],
  [[%.%#panicked at \'%m\'\, %f:%l:%c]],
  [[%E %#--> %f:%l:%c]],
}, ",")

---@class rust.CargoTarget
---@field name string
---@field kinds string[]

---@class rust.CargoPackage
---@field name string
---@field manifest string
---@field targets rust.CargoTarget[]
---@field dependencies string[]

---@class rust.CargoWorkspace
---@field root string
---@field target_dir string
---@field packages rust.CargoPackage[]

---@param text string
---@return rust.CargoWorkspace? workspace
---@return string? error
function M.parse_metadata(text)
  local ok, data = pcall(vim.json.decode, text)
  if not ok or type(data) ~= "table" then return nil, "cargo metadata did not return JSON" end
  if type(data.workspace_root) ~= "string" then return nil, "cargo metadata returned no workspace_root" end

  local members = {}
  for _, id in ipairs(data.workspace_members or {}) do
    members[id] = true
  end

  local packages = {}
  for _, pkg in ipairs(data.packages or {}) do
    if members[pkg.id] then
      local targets = {}
      for _, target in ipairs(pkg.targets or {}) do
        targets[#targets + 1] = { name = target.name, kinds = target.kind or {} }
      end
      local dependencies = {}
      for _, dep in ipairs(pkg.dependencies or {}) do
        dependencies[#dependencies + 1] = dep.name
      end
      packages[#packages + 1] = {
        name = pkg.name,
        manifest = pkg.manifest_path,
        targets = targets,
        dependencies = dependencies,
      }
    end
  end
  table.sort(packages, function(a, b) return a.name < b.name end)

  return {
    root = data.workspace_root,
    target_dir = data.target_directory or vim.fs.joinpath(data.workspace_root, "target"),
    packages = packages,
  }
end

---@param workspace rust.CargoWorkspace
---@param name? string
---@return rust.CargoPackage?
function M.package(workspace, name)
  if not name or name == "" then return workspace.packages[1] end
  for _, pkg in ipairs(workspace.packages) do
    if pkg.name == name then return pkg end
  end
end

---@param pkg rust.CargoPackage?
---@param kind string
---@return string[]
function M.targets(pkg, kind)
  local names = {}
  if not pkg then return names end
  for _, target in ipairs(pkg.targets) do
    if vim.tbl_contains(target.kinds, kind) then names[#names + 1] = target.name end
  end
  return names
end

---@param workspace rust.CargoWorkspace
---@return string[]
function M.binaries(workspace)
  local names = {}
  for _, pkg in ipairs(workspace.packages) do
    vim.list_extend(names, M.targets(pkg, "bin"))
  end
  table.sort(names)
  return names
end

---@param entries string[]?
---@return table<string, string>?
function M.parse_env(entries)
  if not entries or vim.tbl_isempty(entries) then return end
  local env, any = {}, false
  for _, entry in ipairs(entries) do
    local key, value = entry:match "^%s*([%w_]+)%s*=(.*)$"
    if key then
      env[key] = vim.trim(value)
      any = true
    end
  end
  return any and env or nil
end

---@type table<string, rust.CargoWorkspace>
local cache = {}

--- Blocking, but only ever reached from a keypress.
---@param path string
---@return rust.CargoWorkspace? workspace
---@return string? error
function M.workspace(path)
  local root = vim.fs.root(path, MANIFEST)
  if not root then return nil, ("no %s above %s"):format(MANIFEST, vim.fn.fnamemodify(path, ":~")) end
  if cache[root] then return cache[root] end
  if vim.fn.executable "cargo" ~= 1 then return nil, "cargo is not on PATH" end

  local result = vim
    .system({
      "cargo",
      "metadata",
      "--no-deps",
      "--format-version",
      "1",
      "--manifest-path",
      vim.fs.joinpath(root, MANIFEST),
    }, { text = true })
    :wait(15000)

  if result.code ~= 0 then
    local stderr = vim.trim(result.stderr or "")
    return nil, stderr ~= "" and stderr:gsub("\n.*", "") or "cargo metadata failed"
  end

  local workspace, err = M.parse_metadata(result.stdout or "")
  if not workspace then return nil, err end
  cache[root] = workspace
  return workspace
end

function M.invalidate() cache = {} end

return M
