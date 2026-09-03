local M = {}

local function with_root(fn)
  return function()
    local root = require("user.integrations.unity").require_root()
    if root then fn(root) end
  end
end

local function message(type_name, notification)
  return with_root(function(root)
    local instance = require("user.integrations.unity.editor").require_for_project(root)
    if not instance then return end
    local messenger = require "user.integrations.unity.messenger"
    messenger.send_checked(
      instance,
      messenger.TYPE[type_name],
      nil,
      function() vim.notify(notification, vim.log.levels.INFO, { title = "Unity" }) end
    )
  end)
end

M.play = message("Play", "Entering play mode")
M.stop = message("Stop", "Leaving play mode")
M.pause = message("Pause", "Paused")
M.resume = message("Unpause", "Resumed")
M.refresh = message("Refresh", "Refreshing assets")

M.restart = with_root(function(root)
  local instance = require("user.integrations.unity.editor").require_for_project(root)
  if instance then require("user.integrations.unity.play").restart(instance) end
end)

function M.test_cursor() require("user.integrations.unity.tests").run_at_cursor "EditMode" end
function M.test_edit() require("user.integrations.unity.tests").pick "EditMode" end
function M.test_play() require("user.integrations.unity.tests").pick "PlayMode" end
function M.attach() require("user.integrations.unity.dap").attach() end
function M.errors() require("user.integrations.unity.log").errors() end
function M.warnings() require("user.integrations.unity.log").errors(true) end
function M.log() require("user.integrations.unity.log").tail() end
function M.docs() require("user.integrations.unity.docs").open() end
function M.status() require("user.integrations.unity.shim").status() end
function M.install() require("user.integrations.unity.shim").install() end

return M
