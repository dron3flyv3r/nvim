-- Restarting play mode: leave it, wait for Unity to actually be back, enter it.
--
-- WHY THIS IS NOT `send(Stop); send(Play)`. Unity drains the whole queue in one
-- editor frame (`VisualStudioIntegration.OnUpdate`):
--
--     while (_incoming.Count > 0) ProcessIncoming(_incoming.Dequeue());
--
-- and both handlers are plain assignments -- `EditorApplication.isPlaying =
-- false` for Stop, `= true` for Play -- which Unity applies at the end of the
-- frame. Send them back to back and the last write wins: the editor stays in
-- play mode, no domain reload happens, and nothing is actually restarted. The
-- keys look like they worked and the game keeps its state.
--
-- So Play has to wait until the editor has genuinely left play mode.
--
-- HOW WE KNOW IT HAS. Leaving play mode reloads the AppDomain (the default; the
-- Enter Play Mode Options can turn it off), and while a reload is in progress
-- `EditorApplication.update` does not run -- so nothing drains the message
-- queue and pings go unanswered. That silence is the signal.
--
-- It has to be the *answer* we watch and not the socket, because on Linux
-- Unity never closes the old one: `RunOnShutdown` is behind
-- `#if UNITY_EDITOR_WIN`, so the port stays bound through the reload by a
-- socket with nobody listening behind it. `ss -lunp` cannot tell the difference.
--
--     Stop -> pings go quiet -> pings come back -> Play
--
-- If the pings never go quiet, the editor was not playing (or has domain
-- reloading switched off, in which case Stop took effect within a frame
-- anyway). Either way, after a short settle we just press Play -- which is the
-- "if it wasn't running, start it" half of the feature, and it needs no special
-- case.
--
-- A stalled editor -- a long asset import, a GC pause -- can also make one ping
-- time out, and that false positive is harmless: it puts us in "wait for the
-- pings to come back", which is where we wanted to be anyway.

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
  local messenger = require "user.unity_messenger"

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
