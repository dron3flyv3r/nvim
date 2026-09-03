local M = {}

--- How long the editor has to keep answering before we believe no domain reload
--- is coming. A reload triggered by leaving play mode starts within a frame or
--- two, so this only has to outlast a couple of slow frames.
local SETTLE_MS = 600

--- Per-ping patience. Loopback, so an answer is microseconds away when the
--- update loop is running; anything longer than this means it is not.
local PING_MS = 250

--- How long we wait for the editor to come back before giving up and saying so.
--- Domain reloads on a large project are measured in seconds, not milliseconds.
local DEADLINE_MS = 30000

--- Stop play mode if it is running, then start it. Safe to press when nothing
--- is playing: it just starts.
---@param instance UnityInstance
function M.restart(instance)
  local messenger = require "user.integrations.unity.messenger"

  -- The same guard `send_checked` gives every other key: distinguish "Unity is
  -- not listening" from "the key did nothing", before we start a sequence whose
  -- whole premise is that pings mean something.
  messenger.ping(instance, function(listening)
    if not listening then
      vim.notify(
        "Unity is running but its Visual Studio integration is not listening.\n"
          .. "Run `:UnityShim` to point Unity's External Script Editor at Neovim.",
        vim.log.levels.WARN,
        { title = "Unity" }
      )
      return
    end

    messenger.send(instance, messenger.TYPE.Stop)
    vim.notify("Restarting play mode", vim.log.levels.INFO, { title = "Unity" })

    local started = vim.uv.now()
    local reloading = false

    local function play()
      messenger.send(instance, messenger.TYPE.Play)
      vim.notify("Entering play mode", vim.log.levels.INFO, { title = "Unity" })
    end

    local function watch()
      if vim.uv.now() - started > DEADLINE_MS then
        vim.notify(
          "Unity stopped answering after Stop and did not come back, so play mode was not restarted.",
          vim.log.levels.WARN,
          { title = "Unity" }
        )
        return
      end

      messenger.ping(instance, function(answered)
        if reloading then
          -- Waiting for the far side of the domain reload.
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
