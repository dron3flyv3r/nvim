-- `cargo metadata`, reduced to the handful of facts the watcher needs: which
-- packages a workspace has, which binaries they build, where Cargo drops the
-- artifact, and whether the project is wired for dylib hot reloading.
--
-- Everything that turns parameters into an argv lives here as a pure function
-- so `tests/rust_watch_spec.lua` can check it without a Cargo project.
local M = {}

local MANIFEST = "Cargo.toml"

---@class user.rust.CargoTarget
---@field name string
---@field kinds string[] `bin`, `lib`, `cdylib`, `example`, ...

---@class user.rust.CargoPackage
---@field name string
---@field manifest string
---@field targets user.rust.CargoTarget[]
---@field dependencies string[]

---@class user.rust.CargoWorkspace
---@field root string the workspace root, not the nearest manifest
---@field target_dir string
---@field packages user.rust.CargoPackage[] workspace members only, sorted

---@class user.rust.WatchParams
---@field mode "run"|"build"
---@field package string
---@field target string
---@field target_kind "bin"|"example"
---@field profile "dev"|"release"
---@field features string[]
---@field args string[]
---@field env string[] `KEY=VALUE` entries
---@field delay integer
---@field paths string[]
---@field watch_mode "autocmd"|"uv"

--- Reduce `cargo metadata --no-deps` output to a workspace.
---@param text string
---@return user.rust.CargoWorkspace? workspace
---@return string? error
function M.parse_metadata(text)
  local ok, data = pcall(vim.json.decode, text)
  if not ok or type(data) ~= "table" then return nil, "cargo metadata did not return JSON" end
  if type(data.workspace_root) ~= "string" then return nil, "cargo metadata returned no workspace_root" end

  -- `--no-deps` already limits `packages` to members, but the ids are the
  -- authoritative list and cost nothing to honour.
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

---@param workspace user.rust.CargoWorkspace
---@param name string?
---@return user.rust.CargoPackage?
function M.package(workspace, name)
  if not name or name == "" then return workspace.packages[1] end
  for _, pkg in ipairs(workspace.packages) do
    if pkg.name == name then return pkg end
  end
end

--- Names of every target of `kind` in `pkg`.
---@param pkg user.rust.CargoPackage?
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

--- The package to rebuild when the process reloads its own code.
---
--- `hot-lib-reloader` splits a project in two: a host binary that owns the
--- window and the state, and a `cdylib` holding the frame logic it `dlopen`s.
--- Only the second one is worth rebuilding on save -- restarting the host is
--- the exact thing that setup exists to avoid. Detection needs both halves,
--- since a `cdylib` alone is just as likely to be an FFI artifact.
---@param workspace user.rust.CargoWorkspace
---@return user.rust.CargoPackage? lib
function M.hot_reload_lib(workspace)
  local reloads = false
  for _, pkg in ipairs(workspace.packages) do
    if vim.tbl_contains(pkg.dependencies, "hot-lib-reloader") then reloads = true end
  end
  if not reloads then return end

  for _, pkg in ipairs(workspace.packages) do
    if #M.targets(pkg, "cdylib") > 0 then return pkg end
  end
end

--- The argv for one pass of the watcher.
---
--- Always `build`, never `run`, even in run mode: a failed `cargo run` leaves
--- you with no process at all, and keeping the last good binary alive is the
--- whole point. `watch.lua` launches the artifact itself once this succeeds.
---@param params user.rust.WatchParams
---@return string[]
function M.build_args(params)
  local args = { "build" }
  if params.package and params.package ~= "" then vim.list_extend(args, { "--package", params.package }) end
  if params.target and params.target ~= "" then
    vim.list_extend(args, { "--" .. (params.target_kind or "bin"), params.target })
  end
  if params.profile == "release" then table.insert(args, "--release") end
  if params.features and not vim.tbl_isempty(params.features) then
    vim.list_extend(args, { "--features", table.concat(params.features, ",") })
  end
  return args
end

--- Where Cargo puts what `build_args` builds.
---@param workspace user.rust.CargoWorkspace
---@param params user.rust.WatchParams
---@return string? path
function M.executable(workspace, params)
  local name = params.target
  if not name or name == "" then
    -- No explicit target: Cargo would build the package's only binary, so
    -- that is the one to launch. More than one and there is nothing to guess.
    local bins = M.targets(M.package(workspace, params.package), "bin")
    if #bins ~= 1 then return end
    name = bins[1]
  end

  local dir = vim.fs.joinpath(workspace.target_dir, params.profile == "release" and "release" or "debug")
  if params.target_kind == "example" then dir = vim.fs.joinpath(dir, "examples") end
  return vim.fs.joinpath(dir, name)
end

--- `{"RUST_LOG=debug"}` as Overseer wants it. Malformed entries are dropped
--- rather than failing the run -- the form is free text.
---@param entries string[]?
---@return table<string, string>?
function M.parse_env(entries)
  if not entries or vim.tbl_isempty(entries) then return end
  local env = {}
  local any = false
  for _, entry in ipairs(entries) do
    local key, value = entry:match "^%s*([%w_]+)%s*=(.*)$"
    if key then
      env[key] = vim.trim(value)
      any = true
    end
  end
  return any and env or nil
end

---@type table<string, user.rust.CargoWorkspace>
local cache = {}

--- The workspace `path` belongs to, running `cargo metadata` at most once per
--- manifest. Blocking, but only ever from a keypress.
---@param path string a file or directory inside the project
---@return user.rust.CargoWorkspace? workspace
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

--- Forget cached metadata, for when a member or target was added.
function M.invalidate() cache = {} end

return M
