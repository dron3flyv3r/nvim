-- Recognising a Unity project, and finding the pieces of it that everything
-- else in the Unity support needs: the root, the solution, the editor version.
--
-- WHY THIS IS NOT `vim.fs.root`: a Unity project has no single marker file.
-- `Assets/` alone is not enough (asset pipelines, Godot projects and half the
-- game jams on disk have one) and `.sln` is worse -- see `solution()` below for
-- what a real project's root looks like. The pair that actually means "Unity"
-- is `Assets/` next to `ProjectSettings/ProjectVersion.txt`, because
-- ProjectVersion.txt is written by the editor itself and by nothing else.
--
-- Everything here is a pure lookup with no side effects, so it is safe to call
-- from an autocmd on every `BufEnter`. The results are cached per directory:
-- walking to the filesystem root and `stat`-ing two paths at each level is
-- cheap, but not cheap enough to do on every keystroke-adjacent event.

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

--- `M.root`, or a notification and nil.
---
--- Every user-facing command in the Unity support starts with this: they are
--- all no-ops outside a project and the reason needs saying out loud, because
--- "nothing happened" is otherwise indistinguishable from a broken keymap.
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

--- The Unity binary that matches the project's version.
---
--- Hub installs land in `~/Unity/Hub/Editor/<version>/Editor/Unity` by default;
--- `$UNITY_EDITOR` overrides for anything else (a manual install, a second Hub
--- root, a version you are testing against).
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

--- The solution file a language server should be told to open.
---
--- WHY THIS IS NOT "the first .sln in the root": a Unity project root
--- accumulates them. A real example from this machine, `~/git/display_master`:
---
---     display_master.sln   <- the current one, named after the project folder
---     display.sln          <- stale, from before the folder was renamed
---     GodotDisplay.sln     <- a different engine's project entirely
---
--- `nvim-lspconfig`'s `roslyn_ls` config takes whichever one `vim.fs.dir`
--- yields first, which is arbitrary. Loading `GodotDisplay.sln` gives you a
--- server that has never heard of `UnityEngine`, and the symptom is not an
--- error -- it is completion that silently only knows about `System`.
---
--- Unity names the solution after the project directory, so that is the first
--- guess. Failing that (a folder renamed since the last project regeneration),
--- look for the one that references `Assembly-CSharp.csproj` -- the assembly
--- Unity generates for loose scripts under `Assets/`, which no non-Unity
--- solution has.
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
