local M = {}

--- `dir` -> project root, or `false` for "walked to `/`, found nothing".
---@type table<string, string|false>
local roots = {}

---@param dir string
---@return boolean
local function is_project(dir)
  return vim.fn.isdirectory(dir .. "/Assets") == 1
    and vim.fn.filereadable(dir .. "/ProjectSettings/ProjectVersion.txt") == 1
end

--- The directory to start walking up from.
---@param start? string|integer A path, a buffer number, or nil for the current buffer.
---@return string|nil
local function start_dir(start)
  if type(start) == "number" then start = vim.api.nvim_buf_get_name(start) end
  if start == nil then
    local name = vim.api.nvim_buf_get_name(0)
    -- An unnamed buffer (the dashboard, a scratch) tells us nothing about
    -- which project we are in; the cwd does.
    start = name ~= "" and name or vim.fn.getcwd()
  end
  if start == "" then return nil end
  start = vim.fn.fnamemodify(start, ":p")
  -- Buffer names for things like `oil://` or a terminal are not paths.
  if not vim.startswith(start, "/") then return nil end
  return vim.fn.isdirectory(start) == 1 and start:gsub("/$", "") or vim.fs.dirname(start)
end

--- The Unity project directory containing `start`, if there is one.
---@param start? string|integer A path, a buffer number, or nil for the current buffer.
---@return string|nil root
function M.root(start)
  local dir = start_dir(start)
  if not dir then return nil end

  local cached = roots[dir]
  if cached ~= nil then return cached or nil end

  local found ---@type string|nil
  if is_project(dir) then
    found = dir
  else
    for parent in vim.fs.parents(dir) do
      if is_project(parent) then
        found = parent
        break
      end
    end
  end

  roots[dir] = found or false
  return found
end

---@return string|nil root
function M.require_root()
  local root = M.root()
  if not root then
    vim.notify(
      "Not inside a Unity project (no Assets/ + ProjectSettings/ above this buffer)",
      vim.log.levels.WARN,
      { title = "Unity" }
    )
  end
  return root
end

--- Forget the cached lookups. For after a project is created or moved.
function M.clear_cache() roots = {} end

--- The editor version the project was last opened with, e.g. `6000.3.14f1`.
---@param root string
---@return string|nil
function M.editor_version(root)
  local lines = vim.fn.readfile(root .. "/ProjectSettings/ProjectVersion.txt", "", 4)
  for _, line in ipairs(lines) do
    -- `m_EditorVersion: 6000.3.14f1`, and below it `m_EditorVersionWithRevision`
    -- with the hash appended -- match the plain one only.
    local version = line:match "^m_EditorVersion:%s*(%S+)"
    if version then return version end
  end
end

---@param root string
---@return string|nil exe
---@return string|nil version
function M.editor_exe(root)
  local version = M.editor_version(root)
  if vim.env.UNITY_EDITOR and vim.fn.executable(vim.env.UNITY_EDITOR) == 1 then return vim.env.UNITY_EDITOR, version end
  if not version then return nil, nil end

  local home = vim.fn.expand "~"
  for _, candidate in ipairs {
    home .. "/Unity/Hub/Editor/" .. version .. "/Editor/Unity",
    "/opt/unity/editors/" .. version .. "/Editor/Unity",
    home .. "/Applications/Unity/Hub/Editor/" .. version .. "/Unity.app/Contents/MacOS/Unity",
  } do
    if vim.fn.executable(candidate) == 1 then return candidate, version end
  end
  return nil, version
end

---@param root string
---@return string|nil
function M.solution(root)
  local named = root .. "/" .. vim.fs.basename(root) .. ".sln"
  if vim.fn.filereadable(named) == 1 then return named end

  local first ---@type string|nil
  for name, type in vim.fs.dir(root) do
    if type == "file" and name:match "%.slnx?$" then
      local path = root .. "/" .. name
      first = first or path
      local ok, content = pcall(vim.fn.readfile, path)
      -- `%-` because `-` is a Lua pattern quantifier.
      if ok and table.concat(content, "\n"):find "Assembly%-CSharp%.csproj" then return path end
    end
  end
  return first
end

--- Unity's editor log -- the one the editor appends to as it compiles and runs.
---@return string
function M.log_file()
  if vim.fn.has "mac" == 1 then return vim.fn.expand "~/Library/Logs/Unity/Editor.log" end
  if vim.fn.has "win32" == 1 then return vim.fn.expand "$LOCALAPPDATA/Unity/Editor/Editor.log" end
  return vim.fn.expand "~/.config/unity3d/Editor.log"
end

return M
