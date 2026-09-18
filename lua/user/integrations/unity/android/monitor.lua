-- One cheap question, asked on a timer: is the app still the same process?
--
-- `adb logcat --pid=N` does not end when the app does -- it goes quiet, which is
-- indistinguishable from an app with nothing to say. So something has to notice
-- the pid changed, and that is all this does. It used to sample processor and
-- memory counters too; that cost more than it was worth and is gone.
local M = {}

--- A restart should be picked up quickly, but nothing here is urgent enough to
--- pay for it every second.
M.INTERVAL = 5000

--- An unplugged tablet should not leave a timer asking after it all session.
local MAX_FAILURES = 5

local state = {
  timer = nil, ---@type uv.uv_timer_t|nil
  serial = nil, ---@type string|nil
  app_id = nil, ---@type string|nil
  root = nil, ---@type string|nil
  inflight = false,
  failures = 0,
  present = nil, ---@type boolean|nil
}

local function logcat() return require "user.integrations.unity.android.logcat" end

---@param message string
---@param level? integer
local function notify(message, level) vim.notify(message, level or vim.log.levels.INFO, { title = "Unity Android" }) end

---@return boolean
function M.running() return state.timer ~= nil end

--- The app came back as a different process. The log follows by pid, so it would
--- otherwise sit on a stream that has quietly stopped.
---@param pid integer
local function reconnect(pid)
  if not logcat().running() then return end
  if logcat().start(state.serial, pid, state.root) then
    notify(("%s restarted (pid %d) -- log reconnected.\nRe-run the attach to debug it."):format(state.app_id, pid))
  else
    notify(("%s restarted (pid %d), but the log could not reconnect"):format(state.app_id, pid), vim.log.levels.WARN)
  end
end

---@param pid integer 0 when the app is not running.
local function absorb(pid)
  -- Against the pid the log is on rather than one we remember: it catches a
  -- swap, a gone-and-back, and a log started on a stale pid, without three
  -- branches that each have to be right.
  if pid ~= 0 and logcat().running() and logcat().pid() ~= pid then
    reconnect(pid)
  elseif pid == 0 and state.present then
    notify(("%s is no longer running"):format(state.app_id), vim.log.levels.WARN)
  end
  state.present = pid ~= 0
end

local function poll()
  if state.inflight or not state.serial then return end
  state.inflight = true

  local device = require "user.integrations.unity.android.device"
  local adb = device.adb()
  if not adb then
    state.inflight = false
    return M.stop()
  end

  local ok = pcall(
    vim.system,
    { adb, "-s", state.serial, "shell", ("pidof -s %s"):format(state.app_id) },
    { text = true },
    vim.schedule_wrap(function(result)
      state.inflight = false
      if not M.running() then return end

      -- `pidof` exits non-zero when it finds nothing, which is an answer rather
      -- than a failure; only adb itself failing counts against the device.
      if result.code ~= 0 and (result.stderr or "") ~= "" then
        state.failures = state.failures + 1
        if state.failures >= MAX_FAILURES then
          notify("Lost the device -- no longer watching it", vim.log.levels.WARN)
          M.stop()
        end
        return
      end

      state.failures = 0
      absorb(tonumber(vim.trim(result.stdout or "")) or 0)
    end)
  )
  if not ok then state.inflight = false end
end

--- Watch one app on one device. Idempotent for the same target.
---@param serial string
---@param app_id string
---@param root string|nil
function M.start(serial, app_id, root)
  if state.timer and state.serial == serial and state.app_id == app_id then return end
  M.stop()

  state.serial, state.app_id, state.root = serial, app_id, root
  state.present, state.failures = nil, 0

  state.timer = assert(vim.uv.new_timer())
  state.timer:start(M.INTERVAL, M.INTERVAL, vim.schedule_wrap(poll))
end

function M.stop()
  if state.timer then
    state.timer:stop()
    if not state.timer:is_closing() then state.timer:close() end
    state.timer = nil
  end
  state.serial, state.app_id, state.root, state.present = nil, nil, nil, nil
end

return M
