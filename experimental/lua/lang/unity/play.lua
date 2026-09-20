local messenger = require "lang.unity.messenger"

local M = {}

--- How long the editor has to keep answering before we believe no domain
--- reload is coming. A reload triggered by leaving play mode starts within a
--- frame or two, so this only has to outlast a couple of slow frames.
local SETTLE_MS = 600

--- Per-ping patience. Loopback, so an answer is microseconds away when the
--- update loop is running; longer than this means it is not.
local PING_MS = 250

local DEADLINE_MS = 30000

---@param message string
---@param level? integer
local function notify(message, level) vim.notify(message, level or vim.log.levels.INFO, { title = "Unity" }) end

--- Stop play mode if it is running, then start it. Safe when nothing is
--- playing: it just starts.
---@param instance unity.Instance
function M.restart(instance)
  messenger.ping(instance, function(listening)
    if not listening then return notify(messenger.NOT_LISTENING, vim.log.levels.WARN) end

    messenger.send(instance, messenger.TYPE.Stop)
    notify "Restarting play mode"

    local started = vim.uv.now()
    local reloading = false

    local function play()
      messenger.send(instance, messenger.TYPE.Play)
      notify "Entering play mode"
    end

    local function watch()
      if vim.uv.now() - started > DEADLINE_MS then
        return notify(
          "Unity stopped answering after Stop and did not come back, so play mode was not restarted.",
          vim.log.levels.WARN
        )
      end

      messenger.ping(instance, function(answered)
        if reloading then
          if answered then return play() end
        else
          if not answered then
            reloading = true
          elseif vim.uv.now() - started >= SETTLE_MS then
            -- Still answering after the settle: nothing reloaded, because
            -- nothing was playing.
            return play()
          end
        end
        watch()
      end, PING_MS)
    end

    watch()
  end)
end

return M
