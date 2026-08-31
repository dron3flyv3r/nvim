local M = { id = "unity", name = "Unity", priority = 90 }

function M.detect(ctx)
  local root = require("user.integrations.unity").root(ctx.bufnr)
  return root and vim.fn.fnamemodify(root, ":~") or false
end

local function with_root(fn)
  return function()
    local root = require("user.integrations.unity").require_root()
    if root then fn(root) end
  end
end

local function message(type_name, said)
  return with_root(function(root)
    local instance = require("user.integrations.unity.editor").require_for_project(root)
    if not instance then return end
    local messenger = require "user.integrations.unity.messenger"
    messenger.send_checked(instance, messenger.TYPE[type_name], nil, function()
      vim.notify(said, vim.log.levels.INFO, { title = "Unity" })
    end)
  end)
end

local function restart()
  with_root(function(root)
    local instance = require("user.integrations.unity.editor").require_for_project(root)
    if instance then require("user.integrations.unity.play").restart(instance) end
  end)()
end

function M.actions()
  return {
    { id = "unity.play", label = "Enter Play mode", category = "Run", verb = "run", run = message("Play", "Entering play mode"), repeat_action = restart },
    { id = "unity.stop", label = "Stop Play mode", category = "Run", verb = "stop", priority = 100, run = message("Stop", "Leaving play mode") },
    { id = "unity.restart", label = "Restart Play mode", category = "Run", run = restart },
    { id = "unity.pause", label = "Pause Play mode", category = "Run", run = message("Pause", "Paused") },
    { id = "unity.unpause", label = "Resume Play mode", category = "Run", run = message("Unpause", "Resumed") },
    { id = "unity.refresh", label = "Refresh assets and recompile", category = "Build", verb = "build", run = message("Refresh", "Refreshing assets") },
    { id = "unity.test_cursor", label = "Run EditMode test under cursor", category = "Tests", verb = "test", run = function() require("user.integrations.unity.tests").run_at_cursor "EditMode" end },
    { id = "unity.test_edit", label = "Choose EditMode test", category = "Tests", run = function() require("user.integrations.unity.tests").pick "EditMode" end },
    { id = "unity.test_play", label = "Choose PlayMode test", category = "Tests", run = function() require("user.integrations.unity.tests").pick "PlayMode" end },
    { id = "unity.debug", label = "Attach debugger to Unity", category = "Debug", verb = "debug", run = function() require("user.integrations.unity.dap").attach() end },
    { id = "unity.errors", label = "Load compiler errors", category = "Problems", run = function() require("user.integrations.unity.log").errors() end },
    { id = "unity.warnings", label = "Load compiler errors and warnings", category = "Problems", run = function() require("user.integrations.unity.log").errors(true) end },
    { id = "unity.log", label = "Follow Unity editor log", category = "Output", verb = "output", priority = 100, run = function() require("user.integrations.unity.log").tail() end },
    { id = "unity.docs", label = "Open Unity docs for symbol", category = "Inspect", run = function() require("user.integrations.unity.docs").open() end },
    { id = "unity.status", label = "Show Unity integration status", category = "Status", run = function() require("user.integrations.unity.shim").status() end },
    { id = "unity.install", label = "Install/update Unity editor shim", category = "Maintenance", run = function() require("user.integrations.unity.shim").install() end },
  }
end

function M.status(ctx)
  local root = require("user.integrations.unity").root(ctx.bufnr)
  return root and { "  Unity root: " .. vim.fn.fnamemodify(root, ":~") } or {}
end

return M
