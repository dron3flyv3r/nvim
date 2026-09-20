local project = require "lang.unity.project"

---@param ctx core.Context
---@return string|nil
local function root_of(ctx) return project.root(ctx.bufnr) end

---@param ctx core.Context
---@return boolean|string
local function editor_running(ctx)
  local root = root_of(ctx)
  if not root then return "Not inside a Unity project" end
  if require("lang.unity.editor").for_project(root) then return true end
  return ("No Unity editor is running with %s open"):format(vim.fs.basename(root))
end

---@param ctx core.Context
---@return boolean|string
local function bridge_installed(ctx)
  local root = root_of(ctx)
  if not root then return "Not inside a Unity project" end
  return require("lang.unity.bridge").installed(root) or "No bridge in this project -- install it first"
end

---@param ctx core.Context
---@return boolean|string
local function editor_available(ctx)
  local root = root_of(ctx)
  if not root then return "Not inside a Unity project" end
  local exe, version = project.editor_exe(root)
  if exe then return true end
  if not version then return "ProjectSettings/ProjectVersion.txt names no editor version" end
  return ("No Unity %s under ~/Unity/Hub/Editor -- set $UNITY_EDITOR to point at it"):format(version)
end

---@param ctx core.Context
---@return boolean|string
local function log_available(ctx)
  local log = project.log_file()
  if vim.fn.filereadable(log) ~= 1 then return "No editor log at " .. vim.fn.fnamemodify(log, ":~") end
  return root_of(ctx) ~= nil or "Not inside a Unity project"
end

--- Send one editor-control message, once we know Unity is listening.
---@param ctx core.Context
---@param type_name string
---@param notification string
local function send(ctx, type_name, notification)
  local root = assert(root_of(ctx))
  local instance = require("lang.unity.editor").require_for_project(root)
  if not instance then return end
  local messenger = require "lang.unity.messenger"
  messenger.send_checked(
    instance,
    messenger.TYPE[type_name],
    nil,
    function() vim.notify(notification, vim.log.levels.INFO, { title = "Unity" }) end
  )
end

local CONTROLS = {
  { id = "play", label = "Enter play mode", type = "Play", said = "Entering play mode" },
  { id = "stop", label = "Leave play mode", type = "Stop", said = "Leaving play mode" },
  { id = "pause", label = "Pause play mode", type = "Pause", said = "Paused" },
  { id = "resume", label = "Resume play mode", type = "Unpause", said = "Resumed" },
}

---@type core.ActionProvider
return {
  name = "Unity",
  priority = 90,

  detect = function(ctx)
    local root = root_of(ctx)
    if not root then return false end
    local state = require("lang.unity.state").get()
    if state.root == root and state.running then return ("%s -- %s"):format(vim.fn.fnamemodify(root, ":~"), state.state) end
    local version = project.editor_version(root)
    return vim.fn.fnamemodify(root, ":~") .. (version and (" (" .. version .. ")") or "")
  end,

  actions = function(ctx)
    local actions = {}

    for _, control in ipairs(CONTROLS) do
      actions[#actions + 1] = {
        id = control.id,
        label = control.label,
        category = "Run",
        available = editor_running,
        run = function() send(ctx, control.type, control.said) end,
      }
    end

    actions[#actions + 1] = {
      id = "restart",
      label = "Restart play mode",
      category = "Run",
      available = editor_running,
      run = function()
        local instance = require("lang.unity.editor").require_for_project(assert(root_of(ctx)))
        if instance then require("lang.unity.play").restart(instance) end
      end,
    }

    actions[#actions + 1] = {
      id = "refresh",
      label = "Refresh assets and recompile",
      category = "Build",
      available = editor_running,
      run = function() send(ctx, "Refresh", "Refreshing assets") end,
    }

    actions[#actions + 1] = {
      id = "open_editor",
      label = "Open the project in the Unity editor",
      category = "Run",
      repeatable = false,
      available = editor_available,
      run = function()
        local root = assert(root_of(ctx))
        local exe = assert(project.editor_exe(root))
        require("core.task").run {
          name = "unity editor",
          cmd = { exe, "-projectPath", root },
          cwd = root,
          queue = false,
          focus = false,
        }
      end,
    }

    actions[#actions + 1] = {
      id = "errors",
      label = "List compile errors",
      category = "Inspect",
      repeatable = false,
      available = function(inner)
        if bridge_installed(inner) == true then return true end
        return log_available(inner)
      end,
      run = function() require("lang.unity.log").errors() end,
    }

    actions[#actions + 1] = {
      id = "warnings",
      label = "List compile errors and warnings",
      category = "Inspect",
      repeatable = false,
      available = function(inner)
        if bridge_installed(inner) == true then return true end
        return log_available(inner)
      end,
      run = function() require("lang.unity.log").errors(true) end,
    }

    actions[#actions + 1] = {
      id = "log",
      label = "Follow the Unity editor log",
      category = "Inspect",
      available = log_available,
      run = function() require("lang.unity.log").tail() end,
    }

    actions[#actions + 1] = {
      id = "docs",
      label = "Open the Unity docs for the symbol under the cursor",
      category = "Inspect",
      repeatable = false,
      run = function() require("lang.unity.docs").open() end,
    }

    actions[#actions + 1] = {
      id = "ping",
      label = "Check that Unity is answering",
      category = "Inspect",
      repeatable = false,
      available = editor_running,
      run = function()
        local messenger = require "lang.unity.messenger"
        local instance = assert(require("lang.unity.editor").for_project(assert(root_of(ctx))))
        messenger.ping(instance, function(listening)
          if listening then
            vim.notify(
              ("Unity is listening (pid %d, port %d)"):format(instance.pid, instance.message_port),
              vim.log.levels.INFO,
              { title = "Unity" }
            )
          else
            vim.notify(messenger.NOT_LISTENING, vim.log.levels.WARN, { title = "Unity" })
          end
        end)
      end,
    }

    actions[#actions + 1] = {
      id = "solution",
      label = "Open the solution file",
      category = "Inspect",
      repeatable = false,
      available = function(inner)
        local root = root_of(inner)
        if not root then return "Not inside a Unity project" end
        return project.solution(root) ~= nil or "Unity has not generated a .sln yet"
      end,
      run = function() vim.cmd.edit(assert(project.solution(assert(root_of(ctx))))) end,
    }

    actions[#actions + 1] = {
      id = "shim_install",
      label = "Install the editor shim (Unity opens files here)",
      category = "Maintenance",
      repeatable = false,
      run = function() require("lang.unity.shim").install() end,
    }

    actions[#actions + 1] = {
      id = "bridge_install",
      label = "Install the state bridge (Unity reports play and compile state)",
      category = "Maintenance",
      repeatable = false,
      run = function() require("lang.unity.bridge").install(root_of(ctx)) end,
    }

    actions[#actions + 1] = {
      id = "bridge_remove",
      label = "Remove the state bridge",
      category = "Maintenance",
      repeatable = false,
      available = bridge_installed,
      run = function() require("lang.unity.bridge").uninstall(root_of(ctx)) end,
    }

    actions[#actions + 1] = {
      id = "forget_root",
      label = "Forget the cached project lookup",
      category = "Maintenance",
      repeatable = false,
      run = function()
        project.clear_cache()
        vim.notify("Unity project lookup cleared", vim.log.levels.INFO, { title = "Unity" })
      end,
    }

    return actions
  end,

  status = function(ctx)
    local root = root_of(ctx)
    if not root then return { "  no Unity project above this buffer" } end

    local exe, version = project.editor_exe(root)
    local solution = project.solution(root)
    local shim = require "lang.unity.shim"
    local bridge = require "lang.unity.bridge"
    local instance = require("lang.unity.editor").for_project(root)
    local state = require("lang.unity.state").get()

    local lines = {
      ("  root: %s"):format(vim.fn.fnamemodify(root, ":~")),
      ("  editor version: %s"):format(version or "unknown"),
      ("  editor: %s"):format(exe or "not installed locally"),
      ("  solution: %s"):format(solution and vim.fn.fnamemodify(solution, ":~") or "not generated"),
      ("  shim: %s"):format(vim.fn.executable(shim.path) == 1 and shim.path or "not installed"),
      ("  open-from-Unity socket: %s"):format(shim.listening(root) and "bound" or "not bound"),
      ("  running editor: %s"):format(
        instance and ("pid %d, debug port %d, message port %d"):format(
          instance.pid,
          instance.debug_port,
          instance.message_port
        ) or "none"
      ),
    }

    if not bridge.installed(root) then
      table.insert(lines, "  bridge: not installed")
      return lines
    end

    table.insert(lines, ("  bridge: installed%s"):format(state.stale and " (out of date -- reinstall it)" or ""))
    table.insert(lines, ("  reported state: %s"):format(state.root == root and state.state or "not watching yet"))
    if state.errors > 0 or state.warnings > 0 then
      table.insert(lines, ("  last compile: %d error(s), %d warning(s)"):format(state.errors, state.warnings))
    end
    return lines
  end,
}
