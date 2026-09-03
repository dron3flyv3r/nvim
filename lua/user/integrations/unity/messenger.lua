local bit = require "bit"

local M = {}

--- `MessageType` from `Editor/Messaging/MessageType.cs`, in declaration order.
--- The numbers are the enum's implicit values, so the order here is the wire
--- format and must not be rearranged.
M.TYPE = {
  None = 0,
  Ping = 1,
  Pong = 2,
  Play = 3,
  Stop = 4,
  Pause = 5,
  Unpause = 6,
  Build = 7,
  Refresh = 8,
  Info = 9,
  Error = 10,
  Warning = 11,
  Open = 12,
  Opened = 13,
  Version = 14,
  UpdatePackage = 15,
  ProjectPath = 16,
  Tcp = 17,
  RunStarted = 18,
  RunFinished = 19,
  TestStarted = 20,
  TestFinished = 21,
  TestListRetrieved = 22,
  RetrieveTestList = 23,
  ExecuteTests = 24,
  ShowUsage = 25,
}

--- Type number -> name, for logging and for dispatching to subscribers.
M.NAME = {} ---@type table<integer, string>
for name, value in pairs(M.TYPE) do
  M.NAME[value] = name
end

--- Little-endian int32. Hand-rolled because `string.pack` is Lua 5.3 and
--- Neovim is LuaJIT (5.1); `bit` is LuaJIT's own and always available.
---@param n integer
---@return string
local function put_i32(n)
  return string.char(
    bit.band(n, 0xff),
    bit.band(bit.rshift(n, 8), 0xff),
    bit.band(bit.rshift(n, 16), 0xff),
    bit.band(bit.rshift(n, 24), 0xff)
  )
end

---@param buf string
---@param pos integer 1-based
---@return integer|nil value
---@return integer next_pos
local function get_i32(buf, pos)
  if #buf < pos + 3 then return nil, pos end
  local a, b, c, d = buf:byte(pos, pos + 3)
  return a + b * 0x100 + c * 0x10000 + d * 0x1000000, pos + 4
end

---@param type integer
---@param value string
---@return string
local function encode(type, value) return put_i32(type) .. put_i32(#value) .. value end

---@param buf string
---@return integer|nil type
---@return string value
local function decode(buf)
  local type, pos = get_i32(buf, 1)
  if not type then return nil, "" end
  local length = get_i32(buf, pos)
  -- `WriteString` writes a bare `0` for an empty string, so a payload-less
  -- message is eight bytes and `length` is legitimately absent or zero.
  if not length or length <= 0 then return type, "" end
  return type, buf:sub(pos + 4, pos + 4 + length - 1)
end

local socket ---@type uv.uv_udp_t|nil
local subscribers = {} ---@type table<integer, fun(value: string, port: integer)[]>

---@param host string
---@param value string `"<port>:<bytes>"`
---@param from_port integer The port the UDP notice came from, for the callbacks.
local function fetch_over_tcp(host, value, from_port)
  local port, size = value:match "^(%d+):(%d+)$"
  if not port then return end
  port, size = tonumber(port), tonumber(size)

  local client = vim.uv.new_tcp()
  if not client then return end
  local chunks, received = {}, 0

  local function finish()
    if not client:is_closing() then client:close() end
    local type, payload = decode(table.concat(chunks))
    if not type then return end
    vim.schedule(function()
      for _, fn in ipairs(subscribers[type] or {}) do
        fn(payload, from_port)
      end
    end)
  end

  client:connect(host, port, function(err)
    if err then
      if not client:is_closing() then client:close() end
      return
    end
    client:read_start(function(read_err, chunk)
      if read_err or not chunk then
        finish()
        return
      end
      table.insert(chunks, chunk)
      received = received + #chunk
      if received >= size then finish() end
    end)
  end)
end

---@return uv.uv_udp_t|nil
local function ensure_socket()
  if socket and not socket:is_closing() then return socket end

  socket = vim.uv.new_udp()
  if not socket then return nil end

  local ok = socket:bind("0.0.0.0", 0, { reuseaddr = true })
  if not ok then
    socket:close()
    socket = nil
    return nil
  end

  socket:recv_start(function(err, data, addr)
    -- `data == nil` with no error is libuv's "nothing to read", not a message.
    if err or not data or not addr then return end
    local type, value = decode(data)
    if not type then return end

    if type == M.TYPE.Tcp then
      fetch_over_tcp(addr.ip, value, addr.port)
      return
    end

    vim.schedule(function()
      for _, fn in ipairs(subscribers[type] or {}) do
        fn(value, addr.port)
      end
    end)
  end)

  return socket
end

---@param type integer One of `M.TYPE`.
---@param fn fun(value: string, port: integer)
---@return fun() off
function M.on(type, fn)
  subscribers[type] = subscribers[type] or {}
  local list = subscribers[type]
  table.insert(list, fn)
  return function()
    for i, existing in ipairs(list) do
      if existing == fn then
        table.remove(list, i)
        return
      end
    end
  end
end

--- Send one message. Fire and forget: UDP, and Unity does not acknowledge.
---@param instance UnityInstance
---@param type integer One of `M.TYPE`.
---@param value? string
---@return boolean sent Whether the datagram left the machine, not whether Unity heard it.
function M.send(instance, type, value)
  local sock = ensure_socket()
  if not sock then
    vim.notify("Could not open a UDP socket for Unity", vim.log.levels.ERROR, { title = "Unity" })
    return false
  end
  sock:send(encode(type, value or ""), "127.0.0.1", instance.message_port, function() end)
  return true
end

---@param instance UnityInstance
---@param callback fun(listening: boolean)
---@param timeout? integer Milliseconds, default 700.
function M.ping(instance, callback, timeout)
  local answered = false
  local timer = assert(vim.uv.new_timer())
  local off ---@type fun()|nil

  local function done(listening)
    if answered then return end
    answered = true
    timer:stop()
    timer:close()
    if off then off() end
    callback(listening)
  end

  off = M.on(M.TYPE.Pong, function(_, port)
    if port == instance.message_port then done(true) end
  end)

  if not M.send(instance, M.TYPE.Ping) then
    done(false)
    return
  end
  timer:start(timeout or 700, 0, function()
    vim.schedule(function() done(false) end)
  end)
end

---@param instance UnityInstance
---@param type integer
---@param value? string
---@param on_sent? fun()
function M.send_checked(instance, type, value, on_sent)
  M.ping(instance, function(listening)
    if not listening then
      vim.notify(
        "Unity is running but its Visual Studio integration is not listening.\n"
          .. "Run `:UnityShim` to point Unity's External Script Editor at Neovim.",
        vim.log.levels.WARN,
        { title = "Unity" }
      )
      return
    end
    M.send(instance, type, value)
    if on_sent then on_sent() end
  end)
end

local keepalive_timer ---@type uv.uv_timer_t|nil

---@param instance UnityInstance
function M.keepalive_start(instance)
  M.keepalive_stop()
  keepalive_timer = assert(vim.uv.new_timer())
  keepalive_timer:start(0, 2000, function()
    vim.schedule(function() M.send(instance, M.TYPE.Ping) end)
  end)
end

function M.keepalive_stop()
  if keepalive_timer then
    keepalive_timer:stop()
    if not keepalive_timer:is_closing() then keepalive_timer:close() end
    keepalive_timer = nil
  end
end

return M
