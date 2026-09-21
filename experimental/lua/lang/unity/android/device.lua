local M = {}

--- Local port -> serial, for every forward this Neovim created. Only ours are
--- torn down: a forward someone else set up is someone else's to remove.
local owned = {}

local cached ---@type string|false|nil

---@class unity.AndroidDevice
---@field serial string
---@field state string `device` when usable; `unauthorized` and `offline` are the ones worth reporting.
---@field model string|nil As Android reports it, e.g. `SM_X356B`.

---@return string|nil
local function locate()
  local found = vim.fn.exepath "adb"
  if found ~= "" then return found end

  -- A Studio install puts it under the SDK, and `$ANDROID_HOME` is unset more
  -- often than not on a machine that only reaches adb through an editor.
  for _, root in ipairs { vim.env.ANDROID_HOME, vim.env.ANDROID_SDK_ROOT, vim.fn.expand "~/Android/Sdk" } do
    if root and root ~= "" then
      local candidate = root .. "/platform-tools/adb"
      if vim.fn.executable(candidate) == 1 then return candidate end
    end
  end
end

---@return string|nil
function M.adb()
  if cached == nil then cached = locate() or false end
  return cached or nil
end

---@return string
function M.install_hint()
  return "Debugging on a device needs `adb`, from the Android platform tools.\n\n"
    .. "  sudo apt install android-tools-adb\n\n"
    .. "or install it through Android Studio's SDK Manager and set $ANDROID_HOME."
end

--- A short probe read for its value, not a task: nothing here is worth a pane.
---@param args string[]
---@param timeout? integer milliseconds
---@return boolean ok
---@return string output
function M.run(args, timeout)
  local adb = M.adb()
  if not adb then return false, "adb is not installed" end

  local ok, result = pcall(
    function() return vim.system(vim.list_extend({ adb }, args), { text = true }):wait(timeout or 5000) end
  )
  if not ok then return false, tostring(result) end
  return result.code == 0, vim.trim((result.stdout or "") .. (result.stderr or ""))
end

--- Without `-s`, adb picks for you, and picks wrong the moment an emulator is up.
---@param serial string
---@param args string[]
---@param timeout? integer
---@return boolean ok
---@return string output
function M.run_on(serial, args, timeout) return M.run(vim.list_extend({ "-s", serial }, args), timeout) end

--- A shell command on the device, so a pipeline runs there. It matters for
--- `logcat`: filtering at the source is a few lines over USB rather than the
--- whole ring buffer.
---@param serial string
---@param script string
---@param timeout? integer
---@return boolean ok
---@return string output
function M.shell(serial, script, timeout) return M.run_on(serial, { "shell", script }, timeout) end

---@param line string
---@return unity.AndroidDevice|nil
local function parse(line)
  local serial, state = line:match "^(%S+)%s+(%S+)"
  if not serial or serial == "" then return nil end
  return { serial = serial, state = state, model = line:match "model:(%S+)" }
end

--- Everything adb can see, usable or not. `unauthorized` is the most common
--- failure by a wide margin and looks exactly like an absent device unless it
--- is carried through to somewhere it can be read.
---@return unity.AndroidDevice[]
function M.list()
  local ok, output = M.run { "devices", "-l" }
  if not ok then return {} end

  local devices = {}
  for line in output:gmatch "[^\n]+" do
    -- The header, and the daemon chatter adb emits on a cold start.
    if not line:match "^List of devices" and not line:match "^%*" and not line:match "^daemon" then
      local device = parse(line)
      if device then devices[#devices + 1] = device end
    end
  end
  return devices
end

---@return unity.AndroidDevice[]
function M.usable()
  return vim.tbl_filter(function(device) return device.state == "device" end, M.list())
end

---@param device unity.AndroidDevice
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

--- Forward a local port to `remote`, preferring the same number so both ends
--- are easy to hold in your head. A Unity editor on that number is exactly the
--- collision this walks past; adb's refusal is the authority, because
--- `SO_REUSEADDR` makes `bindable` only a hint.
---@param serial string
---@param remote integer The port on the device.
---@param preferred? integer
---@return integer|nil local_port
---@return string|nil err
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

--- A forward outlives the session that asked for it, and whoever binds that
--- port next inherits a pipe to a tablet.
function M.cleanup()
  for port in pairs(vim.deepcopy(owned)) do
    M.unforward(port)
  end
end

local watching = false

function M.watch_exit()
  if watching then return end
  watching = true
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("lang_unity_android_forwards", { clear = true }),
    desc = "Remove the adb forwards this session created",
    callback = function() M.cleanup() end,
  })
end

return M
