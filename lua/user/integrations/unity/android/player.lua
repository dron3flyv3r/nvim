-- The app on the device: which one the project builds to, whether it is
-- running, and where its managed debugger is listening.
--
-- The port is the whole problem. Unity announces it on its first log line and
-- never again, so on a build that has been up an hour the announcement has
-- rolled out of the ring buffer -- the normal case, since you attach when
-- something goes wrong rather than at launch. The listening socket is still in
-- `/proc`, so that is what this trusts.
local M = {}

--- The range Unity's players choose their managed-debugger port from. It is not
--- derivable: the editor's own `56000 + pid % 1000` does not hold on a device.
M.PORT_MIN = 56000
M.PORT_MAX = 56999

---@class AndroidPlayer
---@field app_id string
---@field pid integer
---@field uid integer
---@field port integer The managed debugger port, on the device.
---@field backend string|nil `il2cpp` or `mono`, as the build itself reported it.
---@field build_type string|nil `Development` on anything attachable.
---@field version string|nil The Unity version the build was made with.
---@field stripping string|nil
---@field source string Where the description came from: `log` or `project`.

--- One value out of a nested block in Unity's YAML -- a real parse is a lot of
--- machinery for two lookups. Indentation delimits the block: a pattern stopping
--- at the next `key:` would stop at the block's own first line, since its
--- children look exactly like the end it was meant to find.
---@param text string Contents of ProjectSettings.asset.
---@param key string
---@param platform string
---@return string|nil
function M.parse_setting(text, key, platform)
  local depth ---@type integer|nil
  for line in text:gmatch "[^\n]*" do
    local indent, name = line:match "^(%s*)([%w_]+):"
    if depth then
      -- Back out to the key's own level or shallower: the block has ended.
      if name and #indent <= depth then return nil end
      local value = line:match("^%s*" .. platform .. ":%s*(.-)%s*$")
      if value and value ~= "" then return value end
    elseif name == key then
      depth = #indent
    end
  end
end

--- `ScriptingImplementation`: 0 is Mono2x, 1 is IL2CPP. Absent means Unity's
--- per-platform default applies, which cannot be known here -- so say nothing
--- rather than guess.
---@param text string
---@return string|nil
function M.parse_backend(text)
  local value = M.parse_setting(text, "scriptingBackend", "Android")
  if value == "0" then return "mono" end
  if value == "1" then return "il2cpp" end
end

--- The banner Unity logs at startup: facts about the build that is *running*,
--- not about the project. The tablet may hold a build from last week.
---@param text string
---@return table|nil
function M.parse_banner(text)
  local line = text:match "Built from[^\n]*"
  if not line then return nil end
  return {
    version = line:match "Version '([^']+)'",
    build_type = line:match "Build type '([^']+)'",
    backend = line:match "Scripting Backend '([^']+)'",
    stripping = line:match "Stripping '([^']+)'",
  }
end

---@param text string
---@return integer|nil
function M.parse_debugger_port(text)
  local port = text:match "Starting managed debugger on port (%d+)"
  return port and tonumber(port)
end

--- Listening sockets from `/proc/<pid>/net/tcp`, narrowed to the app's own and
--- to Unity's range. That file is the whole network namespace, so every other
--- app's listeners are in it too and `uid` separates them. `0A` is TCP_LISTEN;
--- both columns are hex.
---@param text string
---@param uid integer
---@return integer[] ports
function M.parse_listening(text, uid)
  local ports = {}
  for line in text:gmatch "[^\n]+" do
    local fields = vim.split(vim.trim(line), "%s+", { trimempty = true })
    local address, state, owner = fields[2], fields[4], tonumber(fields[8])
    if address and state == "0A" and owner == uid then
      local port = tonumber(address:match ":(%x+)$" or "", 16)
      if port and port >= M.PORT_MIN and port <= M.PORT_MAX then table.insert(ports, port) end
    end
  end
  table.sort(ports)
  return ports
end

--- The Android application id this project builds to.
---@param root string
---@return string|nil
function M.app_id(root)
  local path = root .. "/ProjectSettings/ProjectSettings.asset"
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or type(lines) ~= "table" then return nil end
  return M.parse_setting("\n" .. table.concat(lines, "\n"), "applicationIdentifier", "Android")
end

---@param root string
---@return string|nil
function M.project_backend(root)
  local path = root .. "/ProjectSettings/ProjectSettings.asset"
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or type(lines) ~= "table" then return nil end
  return M.parse_backend("\n" .. table.concat(lines, "\n"))
end

local function device() return require "user.integrations.unity.android.device" end

---@param serial string
---@param app_id string
---@return integer|nil
function M.pid(serial, app_id)
  local ok, output = device().shell(serial, ("pidof -s %s"):format(app_id))
  if not ok then return nil end
  return tonumber(vim.trim(output))
end

---@param serial string
---@param pid integer
---@return integer|nil
function M.uid(serial, pid)
  local ok, output = device().shell(serial, ("cat /proc/%d/status"):format(pid))
  if not ok then return nil end
  local uid = output:match "\nUid:%s*(%d+)"
  return uid and tonumber(uid)
end

--- Where the managed debugger is listening, or nil when script debugging was
--- not built in.
---@param serial string
---@param pid integer
---@param uid integer
---@return integer|nil
function M.debugger_port(serial, pid, uid)
  local ok, output = device().shell(serial, ("cat /proc/%d/net/tcp /proc/%d/net/tcp6 2>/dev/null"):format(pid, pid))
  if ok then
    local ports = M.parse_listening(output, uid)
    if #ports == 1 then return ports[1] end
    -- More than one candidate means guessing, and guessing wrong costs the
    -- app's single debugger connection. The log knows which it is.
    if #ports > 1 then
      local logged = M.log_port(serial, pid)
      if logged and vim.tbl_contains(ports, logged) then return logged end
    end
  end
  return M.log_port(serial, pid)
end

--- Grepped on the device so only the line we want crosses the cable. Absent on
--- any build that has been up a while.
---@param serial string
---@param pid integer
---@return integer|nil
function M.log_port(serial, pid)
  local ok, output = device().shell(
    serial,
    ("logcat -d --pid=%d -s Unity 2>/dev/null | grep -m1 'managed debugger on port'"):format(pid)
  )
  if not ok then return nil end
  return M.parse_debugger_port(output)
end

--- What the running build says about itself, when it still remembers.
---@param serial string
---@param pid integer
---@return table|nil
function M.banner(serial, pid)
  local ok, output =
    device().shell(serial, ("logcat -d --pid=%d -s Unity 2>/dev/null | grep -m1 'Built from'"):format(pid))
  if not ok then return nil end
  return M.parse_banner(output)
end

--- Everything needed to attach, or a sentence explaining what is missing.
---@param serial string
---@param root string
---@return AndroidPlayer|nil player, string|nil err
function M.inspect(serial, root)
  local app_id = M.app_id(root)
  if not app_id then return nil, "No Android application id in ProjectSettings.asset" end

  local pid = M.pid(serial, app_id)
  if not pid then return nil, ("%s is not running on the device -- start it first"):format(app_id) end

  local uid = M.uid(serial, pid)
  if not uid then return nil, ("Cannot read /proc/%d on the device"):format(pid) end

  local port = M.debugger_port(serial, pid, uid)
  if not port then
    return nil,
      ("%s is running, but nothing is listening for a debugger.\n"):format(app_id)
        .. "Rebuild with Development Build and Script Debugging enabled."
  end

  local player = { app_id = app_id, pid = pid, uid = uid, port = port, source = "log", backend = nil, build_type = nil }
  local banner = M.banner(serial, pid)
  if banner then
    player.version, player.build_type = banner.version, banner.build_type
    player.backend, player.stripping = banner.backend, banner.stripping
  else
    -- The build's own account has aged out, so this is the project's current
    -- setting standing in for it -- true of the next build, not necessarily of
    -- the one on the tablet.
    player.source = "project"
    player.backend = M.project_backend(root)
  end
  return player, nil
end

--- A line worth showing after a successful attach: what it turned out to be.
---@param player AndroidPlayer
---@return string
function M.summary(player)
  local parts = { player.app_id, ("pid %d"):format(player.pid), ("port %d"):format(player.port) }
  if player.backend then
    local note = player.source == "project" and " (project setting)" or ""
    table.insert(parts, player.backend .. note)
  end
  if player.stripping and player.stripping ~= "Disabled" then table.insert(parts, "stripping " .. player.stripping) end
  return table.concat(parts, "  ")
end

return M
