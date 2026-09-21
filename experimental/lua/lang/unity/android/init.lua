local dap_config = require "lang.unity.dap"
local device = require "lang.unity.android.device"
local player = require "lang.unity.android.player"
local project = require "lang.unity.project"

local M = {}

--- The device chosen last time, so a second attach asks nothing.
local remembered ---@type string|nil

---@param message string
---@param level? integer
local function notify(message, level) vim.notify(message, level or vim.log.levels.INFO, { title = "Unity Android" }) end

---@param on_pick fun(device: unity.AndroidDevice)
local function pick_device(on_pick)
  local devices = device.list()
  local usable = vim.tbl_filter(function(entry) return entry.state == "device" end, devices)

  if #usable == 0 then
    if #devices == 0 then
      notify("No device is connected -- plug the tablet in and enable USB debugging", vim.log.levels.WARN)
    else
      -- Almost always `unauthorized`, which looks like a broken cable until you
      -- know to look at the tablet's screen for the prompt.
      local lines = vim.tbl_map(function(entry) return "  " .. device.describe(entry) end, devices)
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
    format_item = function(entry) return device.describe(entry) end,
  }, function(entry)
    if not entry then return end
    remembered = entry.serial
    on_pick(entry)
  end)
end

---@return boolean|string
function M.available()
  if not device.adb() then return "adb is not installed" end
  return dap_config.available()
end

---@return string|nil root
local function prerequisites()
  local root = project.require_root()
  if not root then return nil end

  if not device.adb() then
    notify(device.install_hint(), vim.log.levels.ERROR)
    return nil
  end
  return root
end

---@param local_port integer
local function release_with_session(local_port)
  local dap = require "dap"
  local function release()
    device.unforward(local_port)
    for _, listeners in ipairs { dap.listeners.before, dap.listeners.after } do
      for _, event in ipairs { "event_terminated", "event_exited", "terminate", "disconnect" } do
        if listeners[event] then listeners[event].lang_unity_android = nil end
      end
    end
  end

  dap.listeners.before.event_terminated.lang_unity_android = release
  dap.listeners.before.event_exited.lang_unity_android = release
  dap.listeners.after.terminate.lang_unity_android = release
  dap.listeners.after.disconnect.lang_unity_android = release
end

---@param serial string
---@param pid integer
---@param label string
function M.log(serial, pid, label)
  require("core.task").run {
    name = "logcat " .. label,
    cmd = { assert(device.adb()), "-s", serial, "logcat", ("--pid=%d"):format(pid) },
    queue = false,
    focus = false,
  }
end

--- Attach to the app running on a device. Mechanically this is the editor
--- attach with a longer piece of string -- same adapter, same `attach` request,
--- only pointed at a local port adb has forwarded.
function M.attach()
  local root = prerequisites()
  if not root then return end

  local why = dap_config.available()
  if why ~= true then
    notify(why == "dotnet is not on PATH" and why or dap_config.install_hint(), vim.log.levels.ERROR)
    return
  end

  pick_device(function(chosen)
    local found, err = player.inspect(chosen.serial, root)
    if not found then return notify(err or "Cannot inspect the app", vim.log.levels.WARN) end

    local local_port, forward_err = device.forward(chosen.serial, found.port, found.port)
    if not local_port then
      return notify(("Cannot forward a port to the device: %s"):format(forward_err or "unknown"), vim.log.levels.ERROR)
    end

    release_with_session(local_port)

    local name = ("Android: %s"):format(chosen.model and chosen.model:gsub("_", " ") or chosen.serial)
    require("dap").run(dap_config.attach_config(name, ("127.0.0.1:%d"):format(local_port), root))

    -- The log is the other half of knowing what the tablet is doing, and it is
    -- wanted every time rather than left as a second thing to remember once the
    -- debugger is already up.
    M.log(chosen.serial, found.pid, found.app_id)
    notify(player.summary(found))
  end)
end

--- Follow the app's log with no debugger involved. Deliberately reachable on
--- its own: when an attach has failed, or when what you are chasing takes the
--- app down with it, this is the half that still answers.
function M.watch()
  local root = prerequisites()
  if not root then return end

  pick_device(function(chosen)
    local app_id = player.app_id(root)
    if not app_id then return notify("No Android application id in ProjectSettings.asset", vim.log.levels.WARN) end

    local pid = player.pid(chosen.serial, app_id)
    if not pid then
      return notify(("%s is not running on the device -- start it first"):format(app_id), vim.log.levels.WARN)
    end
    M.log(chosen.serial, pid, app_id)
  end)
end

--- What the tablet looks like from here, without touching the debugger. The app
--- accepts one debugger connection for its lifetime, so when something is wrong
--- the cheap way to find out is to look rather than attach and burn it.
---@param root string
---@return string[]
function M.status(root)
  if not device.adb() then return { "  adb: not installed" } end

  local lines = { ("  app id: %s"):format(player.app_id(root) or "not set in ProjectSettings.asset") }
  local devices = device.list()
  if #devices == 0 then
    lines[#lines + 1] = "  devices: none connected"
    return lines
  end

  for _, entry in ipairs(devices) do
    lines[#lines + 1] = "  device: " .. device.describe(entry)
    if entry.state == "device" then
      local found, err = player.inspect(entry.serial, root)
      lines[#lines + 1] = "    " .. (found and player.summary(found) or err or "unknown")
    end
  end
  return lines
end

--- For when the tablet on the desk is not this morning's.
function M.forget()
  remembered = nil
  notify "Device choice forgotten"
end

return M
