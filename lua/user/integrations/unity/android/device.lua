-- Everything that speaks `adb`: which devices are attached, a local port
-- nothing else holds, and a forward from it to the one the player listens on.
--
-- Each has a way of going quietly wrong that costs an afternoon -- an
-- unauthorised device that looks merely absent, a forward left behind by a
-- previous session, a port another program owns -- so they are gathered here.
local M = {}

--- Every forward this Neovim created: local port -> serial. Only ours are torn
--- down, because a forward someone else set up is someone else's to remove.
local owned = {}

local cached_adb ---@type string|false|nil

---@class AndroidDevice
---@field serial string
---@field state string `device` when usable; `unauthorized` and `offline` are the ones worth reporting.
---@field model string|nil As Android reports it, e.g. `SM_X356B`.

---@return string|nil
local function locate()
  local found = vim.fn.exepath "adb"
  if found ~= "" then return found end

  -- A Studio install puts it under the SDK, and `$ANDROID_HOME` is unset more
  -- often than not on a machine that only ever uses adb through a plugin.
  local roots = { vim.env.ANDROID_HOME, vim.env.ANDROID_SDK_ROOT, vim.fn.expand "~/Android/Sdk" }
  for index = 1, 3 do
    local root = roots[index]
    if root and root ~= "" then
      local candidate = root .. "/platform-tools/adb"
      if vim.fn.executable(candidate) == 1 then return candidate end
    end
  end
end

---@return string|nil
function M.adb()
  if cached_adb == nil then cached_adb = locate() or false end
  return cached_adb or nil
end

---@return string
function M.install_hint()
  return "Debugging on a device needs `adb`, from the Android platform tools.\n\n"
    .. "  sudo apt install android-tools-adb\n\n"
    .. "or install it through Android Studio's SDK Manager and set $ANDROID_HOME."
end

---@param args string[]
---@param timeout? integer milliseconds
---@return boolean ok, string output
function M.run(args, timeout)
  local adb = M.adb()
  if not adb then return false, "adb is not installed" end

  local cmd = { adb }
  vim.list_extend(cmd, args)
  local ok, res = pcall(function() return vim.system(cmd, { text = true }):wait(timeout or 5000) end)
  if not ok then return false, tostring(res) end
  return res.code == 0, vim.trim((res.stdout or "") .. (res.stderr or ""))
end

--- Without `-s`, adb picks for you -- wrong the moment an emulator is up too.
---@param serial string
---@param args string[]
---@param timeout? integer
---@return boolean ok, string output
function M.run_on(serial, args, timeout)
  local full = { "-s", serial }
  vim.list_extend(full, args)
  return M.run(full, timeout)
end

--- A shell command on the device, so pipes and greps run there. It matters for
--- `logcat`: filtering at the source is a few lines over USB, not the whole
--- ring buffer.
---@param serial string
---@param script string
---@param timeout? integer
---@return boolean ok, string output
function M.shell(serial, script, timeout) return M.run_on(serial, { "shell", script }, timeout) end

---@param line string
---@return AndroidDevice|nil
local function parse_device(line)
  local serial, state = line:match "^(%S+)%s+(%S+)"
  if not serial or serial == "" then return nil end
  return { serial = serial, state = state, model = line:match "model:(%S+)" }
end

M.parse_device = parse_device

--- Everything adb can see, usable or not. `unauthorized` is the most common
--- failure by a wide margin, and it looks exactly like an absent device unless
--- it is carried through to where someone can read it.
---@return AndroidDevice[]
function M.list()
  local ok, output = M.run { "devices", "-l" }
  if not ok then return {} end

  local devices = {}
  for line in output:gmatch "[^\n]+" do
    -- The header, and the "daemon started" chatter adb emits on a cold start.
    if not line:match "^List of devices" and not line:match "^%*" and not line:match "^daemon" then
      local device = parse_device(line)
      if device then table.insert(devices, device) end
    end
  end
  return devices
end

---@return AndroidDevice[]
function M.usable()
  return vim.tbl_filter(function(device) return device.state == "device" end, M.list())
end

---@param device AndroidDevice
---@return string
function M.describe(device)
  local name = device.model and device.model:gsub("_", " ") or "unknown device"
  if device.state ~= "device" then return ("%s  (%s -- %s)"):format(name, device.serial, device.state) end
  return ("%s  (%s)"):format(name, device.serial)
end

---@param port integer
---@return boolean
local function bindable(port)
  local server = vim.uv.new_tcp()
  if not server then return true end
  local ok = pcall(function() assert(server:bind("0.0.0.0", port)) end)
  pcall(function() server:close() end)
  return ok
end

--- Forward a local port to `remote`, trying `preferred` first. Mirroring the
--- device's port number keeps both ends easy to hold in your head, but a Unity
--- editor on the same number is exactly the collision this walks past. adb's
--- refusal is the authority: libuv's `SO_REUSEADDR` makes `bindable` a hint.
---@param serial string
---@param remote integer The port on the device.
---@param preferred? integer
---@return integer|nil local_port, string|nil err
function M.forward(serial, remote, preferred)
  local first = preferred or remote
  for offset = 0, 20 do
    local port = first + offset
    if port <= 65535 and bindable(port) then
      local ok, output = M.run_on(serial, { "forward", ("tcp:%d"):format(port), ("tcp:%d"):format(remote) })
      if ok then
        owned[port] = serial
        M.watch_exit()
        return port, nil
      end
      -- Anything that is not a collision will not be fixed by the next port.
      if not output:lower():find "in use" then return nil, output end
    end
  end
  return nil, ("no free local port near %d"):format(first)
end

---@param local_port integer
function M.unforward(local_port)
  local serial = owned[local_port]
  if not serial then return end
  owned[local_port] = nil
  M.run_on(serial, { "forward", "--remove", ("tcp:%d"):format(local_port) })
end

--- A stale forward is silent until the day it answers the wrong connection.
function M.cleanup()
  for port in pairs(vim.deepcopy(owned)) do
    M.unforward(port)
  end
end

local watching = false

--- Idempotent.
function M.watch_exit()
  if watching then return end
  watching = true
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("unity_android_forwards", { clear = true }),
    desc = "Remove the adb forwards this session created",
    callback = function() M.cleanup() end,
  })
end

return M
