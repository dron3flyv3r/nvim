-- Attaching the debugger to a build running on a tablet.
--
-- Mechanically this is the editor attach with a longer piece of string: same
-- adapter, same `attach` request, same `endPoint` -- only pointed at a local port
-- `adb` has forwarded to the device.
--
-- What differs is that every step fails in a way the adapter cannot explain. No
-- device, one never authorised, an app that is not running, a build with no
-- script debugging: all reach the adapter as "connection refused". So the checks
-- happen here, ordered so the first failure is the informative one.
local M = {}

--- The device chosen last time, so a second attach asks nothing.
local remembered ---@type string|nil

local function device() return require "user.integrations.unity.android.device" end
local function player() return require "user.integrations.unity.android.player" end
local function logcat() return require "user.integrations.unity.android.logcat" end
local function monitor() return require "user.integrations.unity.android.monitor" end

---@param message string
---@param level? integer
local function notify(message, level) vim.notify(message, level or vim.log.levels.INFO, { title = "Unity Android" }) end

---@param on_pick fun(device: AndroidDevice)
local function pick_device(on_pick)
  local devices = device().list()
  local usable = vim.tbl_filter(function(entry) return entry.state == "device" end, devices)

  if #usable == 0 then
    if #devices == 0 then
      notify("No device is connected -- plug the tablet in and enable USB debugging", vim.log.levels.WARN)
    else
      -- Almost always `unauthorized`, which looks like a broken cable until you
      -- know to look at the tablet's screen for the prompt.
      local lines = vim.tbl_map(function(entry) return "  " .. device().describe(entry) end, devices)
      notify(
        "No usable device. adb sees:\n" .. table.concat(lines, "\n") .. "\n\nAccept the debugging prompt on the device.",
        vim.log.levels.WARN
      )
    end
    return
  end

  if remembered then
    for _, entry in ipairs(usable) do
      if entry.serial == remembered then return on_pick(entry) end
    end
  end

  if #usable == 1 then
    remembered = usable[1].serial
    return on_pick(usable[1])
  end

  vim.ui.select(usable, {
    prompt = "Attach to which device?",
    format_item = function(entry) return device().describe(entry) end,
  }, function(entry)
    if not entry then return end
    remembered = entry.serial
    on_pick(entry)
  end)
end

--- A Unity project and an adb to reach the tablet with. All the device needs.
---@return string|nil root
local function basics()
  local unity = require "user.integrations.unity"
  local root = unity.require_root()
  if not root then return nil end

  if not device().adb() then
    notify(device().install_hint(), vim.log.levels.ERROR)
    return nil
  end
  return root
end

--- The same, plus the debug adapter. Only attaching needs that -- reading the
--- log does not, and that is the half that still works when the other has gone
--- wrong.
---@return string|nil root
local function prerequisites()
  local root = basics()
  if not root then return nil end

  local dap = require "user.integrations.unity.dap"
  if not dap.extension_path() then
    notify(dap.install_hint(), vim.log.levels.ERROR)
    return nil
  end
  return root
end

--- A forward outlives the debugger that asked for it, and whoever binds that
--- port next inherits a pipe to a tablet.
---@param local_port integer
local function release_with_session(local_port)
  local dap = require "dap"
  local function release()
    device().unforward(local_port)
    for _, listeners in ipairs { dap.listeners.before, dap.listeners.after } do
      for _, event in ipairs { "event_terminated", "event_exited", "terminate", "disconnect" } do
        if listeners[event] then listeners[event].user_android_forward = nil end
      end
    end
  end

  dap.listeners.before.event_terminated.user_android_forward = release
  dap.listeners.before.event_exited.user_android_forward = release
  dap.listeners.after.terminate.user_android_forward = release
  dap.listeners.after.disconnect.user_android_forward = release
end

--- Attach to the app running on a device. The contextual debug action for a
--- Unity project whose target is a tablet.
function M.attach()
  local root = prerequisites()
  if not root then return end

  pick_device(function(chosen)
    local serial = chosen.serial
    local found, err = player().inspect(serial, root)
    if not found then return notify(err or "Cannot inspect the app", vim.log.levels.WARN) end

    local local_port, forward_err = device().forward(serial, found.port, found.port)
    if not local_port then
      return notify(("Cannot forward a port to the device: %s"):format(forward_err or "unknown"), vim.log.levels.ERROR)
    end

    require("user.integrations.unity.dap").setup()
    release_with_session(local_port)

    require("dap").run {
      type = "vstuc",
      request = "attach",
      name = ("Android: %s"):format(chosen.model and chosen.model:gsub("_", " ") or serial),
      -- The sources behind the line numbers in the build's .pdb files.
      projectPath = root,
      endPoint = ("127.0.0.1:%d"):format(local_port),
      logFile = vim.g.unity_dap_log or nil,
    }

    -- The log is the other half of knowing what the tablet is doing, and it is
    -- wanted every time: started here rather than left as a second thing to
    -- remember once the debugger is already attached.
    if not logcat().running() then M.watch(serial, found.app_id, found.pid, root) end
    notify(player().summary(found))
  end)
end

--- The log, and the timer that keeps it attached to the right process. They
--- begin and end together: the timer is what notices a restart, and a log
--- without it is one that goes quiet and never says why.
---@param serial string
---@param app_id string
---@param pid integer
---@param root string|nil
---@return boolean ok, string|nil err
function M.watch(serial, app_id, pid, root)
  local ok, err = logcat().start(serial, pid, root)
  if not ok then return false, err end
  monitor().start(serial, app_id, root)
  return true, nil
end

--- Stop both.
function M.unwatch()
  monitor().stop()
  logcat().stop()
end

--- Follow the app's log with no debugger involved. Deliberately reachable on
--- its own: when an attach has failed, or when what you are chasing takes the
--- app down with it, this is the part that still answers.
function M.log()
  if logcat().running() then
    M.unwatch()
    return notify "Stopped watching the device"
  end

  local root = basics()
  if not root then return end

  pick_device(function(chosen)
    local app_id = player().app_id(root)
    if not app_id then return notify("No Android application id in ProjectSettings.asset", vim.log.levels.WARN) end

    local pid = player().pid(chosen.serial, app_id)
    if not pid then
      return notify(("%s is not running on the device -- start it first"):format(app_id), vim.log.levels.WARN)
    end

    local ok, err = M.watch(chosen.serial, app_id, pid, root)
    if not ok then return notify(err or "Cannot start logcat", vim.log.levels.ERROR) end
    notify(("Watching %s (pid %d)"):format(app_id, pid))
  end)
end

function M.frames() logcat().frames() end

--- What the tablet looks like from here, without touching the debugger. The app
--- accepts one debugger connection for its lifetime, so when something is wrong
--- the cheap way to find out is to look rather than attach and burn it.
function M.status()
  local unity = require "user.integrations.unity"
  local root = unity.require_root()
  if not root then return end

  local lines = { "Unity Android" }
  if not device().adb() then
    notify(device().install_hint(), vim.log.levels.WARN)
    return
  end

  local app_id = player().app_id(root)
  table.insert(lines, "  App id: " .. (app_id or "not set in ProjectSettings.asset"))

  local devices = device().list()
  if #devices == 0 then
    table.insert(lines, "  Devices: none connected")
    notify(table.concat(lines, "\n"))
    return
  end

  for _, entry in ipairs(devices) do
    table.insert(lines, "  Device: " .. device().describe(entry))
    if entry.state == "device" and app_id then
      local found, err = player().inspect(entry.serial, root)
      table.insert(lines, "    " .. (found and player().summary(found) or err or "unknown"))
    end
  end
  notify(table.concat(lines, "\n"))
end

--- For when the tablet on the desk is not this morning's.
function M.forget() remembered = nil end

return M
