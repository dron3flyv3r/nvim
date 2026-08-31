-- Finding the Unity editors that are running right now, and which project each
-- one has open.
--
-- Two things need this: the debugger (which port do I attach to) and the
-- editor remote control (which port do I send Play to). Both need to be sure
-- they picked the *right* Unity, because on this machine there are routinely
-- three or four processes called `Unity` alive at once and only one of them is
-- an editor you can talk to.
--
-- THE PORT FORMULA. Unity derives both of its ports from its own pid:
--
--     debugger  = 56000 + (pid % 1000)      -- the Mono soft-debugger socket
--     messaging = debugger + 2              -- the VS/Unity UDP channel
--
-- That is not a guess -- it is `DebuggingPort()` / `MessagingPort()` in
-- `com.unity.ide.visualstudio`'s `VisualStudioIntegration.cs`, which you can
-- read in any project under
-- `Library/PackageCache/com.unity.ide.visualstudio@*/Editor/`. So a pid is all
-- we need, and there is nothing to discover over the network.
--
-- WHY WE READ `/proc` AND NOT UNITY'S OWN PROBE. The VS Tools for Unity
-- extension ships `UnityAttachProbe.dll`, which finds editors by UDP broadcast
-- and prints them as JSON. It works, and it has one fatal gap for us: its
-- `projectName` field comes back empty, so it cannot tell you which project an
-- editor has open. It also cannot tell an editor from an asset-import worker --
-- run it on this machine with one editor open and it reports three "Editors",
-- because Unity forks `AssetImportWorker` children that inherit the discovery
-- socket. Attaching a debugger to one of those gets you a session that never
-- hits a breakpoint.
--
-- `/proc/<pid>/cmdline` answers both questions exactly, because Unity puts them
-- on its own command line:
--
--     Unity -projectPath /home/me/git/display_master -riderPath ...
--     Unity -adb2 -batchMode -noUpm -name AssetImportWorker6 -projectPath ...
--
-- The worker is the one with `-batchMode`. The editor is the one without.
--
-- WHAT THE EDITOR IS CALLED. Not `Unity`, necessarily. A Hub install of Unity 6
-- runs a per-version launcher:
--
--     ~/Unity/Hub/Editor/6000.3.14f1/Editor/unityhub-unity-editor-6000.3.14f1
--
-- and `/proc/<pid>/comm` is capped at 15 characters (`TASK_COMM_LEN`), so that
-- arrives as the truncated `unityhub-unity-`. Standalone installs and macOS
-- still use `Unity`. Matching either name exactly is therefore a trap, and
-- matching loosely is also a trap -- one editor drags along `Unity.Licensing`,
-- `UnityShaderCompiler`, `UnityPackageManager`, `Unity.ILPP.Runner` and
-- `UnityAutoQuitter`, none of which have a debugger port.
--
-- So `comm` is used only as a cheap prefilter (anything with "unity" in it) and
-- the real test is the command line: an editor is a process that was given a
-- `-projectPath` and was not given `-batchMode`. None of the helpers above take
-- a project path, and every asset-import worker takes `-batchMode`.
--
-- The cost is that this is Linux-only. That is the platform this config runs
-- on, and the alternative -- believing the probe -- is wrong rather than
-- portable. `M.list` simply returns nothing elsewhere, and every caller already
-- has to handle "no editor is running".

local M = {}

---@class UnityInstance
---@field pid integer
---@field project string|nil Absolute path to the project root, if we could read it.
---@field debug_port integer The Mono soft-debugger port -- what nvim-dap attaches to.
---@field message_port integer The VS/Unity UDP port -- what `user.unity_messenger` sends to.

---@param pid integer
---@return string[]|nil argv
local function cmdline(pid)
  local fd = io.open("/proc/" .. pid .. "/cmdline", "rb")
  if not fd then return nil end
  local raw = fd:read "*a"
  fd:close()
  if not raw or raw == "" then return nil end
  -- NUL-separated, with a trailing NUL.
  return vim.split(raw:gsub("%z$", ""), "%z")
end

---@param pid integer
---@return string|nil
local function comm(pid)
  local fd = io.open("/proc/" .. pid .. "/comm", "r")
  if not fd then return nil end
  local name = fd:read "l"
  fd:close()
  return name
end

--- Normalise a project path for comparison: absolute, symlinks resolved, no
--- trailing slash. `-projectPath` is whatever the launcher passed, which for a
--- Hub launch is absolute but for a hand-run editor may not be.
---@param path string
---@return string
local function canonical(path) return (vim.fn.resolve(vim.fn.fnamemodify(path, ":p")):gsub("/$", "")) end

--- Every Unity editor process running for this user, newest pid last.
---@return UnityInstance[]
function M.list()
  local dir = vim.uv.fs_scandir "/proc"
  if not dir then return {} end

  local instances = {} ---@type UnityInstance[]
  while true do
    local name = vim.uv.fs_scandir_next(dir)
    if not name then break end

    local pid = tonumber(name)
    -- `/proc` is full of non-numeric entries (`self`, `cpuinfo`, ...), and
    -- `fs_scandir` gives us `DT_UNKNOWN` for its directories on some kernels,
    -- so filter on the name rather than the type.
    local process = pid and comm(pid)
    if process and process:lower():find("unity", 1, true) then
      local argv = cmdline(pid)
      if argv then
        local project, batch = nil, false
        for i, arg in ipairs(argv) do
          local flag = arg:lower()
          -- Unity accepts `-batchmode`; the workers are spawned with
          -- `-batchMode`; the Hub passes `-projectpath`. Compare lowercased so
          -- every spelling is caught.
          if flag == "-batchmode" then batch = true end
          if flag == "-projectpath" and argv[i + 1] then project = canonical(argv[i + 1]) end
        end
        -- A project path proves this is an editor rather than one of Unity's
        -- helper processes. `comm == "Unity"` is kept as a second way in for a
        -- hand-launched editor that picked its project from the startup dialog
        -- and so has no `-projectPath`: it can never match `for_project`, but it
        -- should still be offerable in the debugger picker.
        if not batch and (project or process == "Unity") then
          table.insert(instances, {
            pid = pid,
            project = project,
            debug_port = 56000 + (pid % 1000),
            message_port = 56000 + (pid % 1000) + 2,
          })
        end
      end
    end
  end

  table.sort(instances, function(a, b) return a.pid < b.pid end)
  return instances
end

--- The editor that has `root` open, if one does.
---@param root string
---@return UnityInstance|nil
function M.for_project(root)
  root = canonical(root)
  for _, instance in ipairs(M.list()) do
    if instance.project == root then return instance end
  end
end

--- The editor for `root`, or a notification and nil.
---@param root string
---@return UnityInstance|nil
function M.require_for_project(root)
  local instance = M.for_project(root)
  if not instance then
    vim.notify(
      ("No Unity editor is running with %s open"):format(vim.fs.basename(root)),
      vim.log.levels.WARN,
      { title = "Unity" }
    )
  end
  return instance
end

--- A one-line label for pickers and notifications.
---@param instance UnityInstance
---@return string
function M.describe(instance)
  return ("%s  (pid %d, port %d)"):format(
    instance.project and vim.fs.basename(instance.project) or "unknown project",
    instance.pid,
    instance.debug_port
  )
end

return M
