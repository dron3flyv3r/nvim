local bit = require "bit"

local M = {}

--- `MessageType` from Unity's `Editor/Messaging/MessageType.cs`, in declaration
--- order. The numbers are the enum's implicit values, so this order is the wire
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

---@type table<integer, string>
M.NAME = {}
for name, value in pairs(M.TYPE) do
  M.NAME[value] = name
end

--- Hand-rolled because `string.pack` is Lua 5.3 and this is LuaJIT.
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
---@param pos integer
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

---@type table<integer, fun(value: string, port: integer)[]>
local subscribers = {}

---@param type integer
---@param payload string
---@param from_port integer
local function dispatch(type, payload, from_port)
  vim.schedule(function()
    for _, fn in ipairs(subscribers[type] or {}) do
      fn(payload, from_port)
    end
  end)
end

---@param host string
---@param value string `"<port>:<bytes>"`
---@param from_port integer
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
    if type then dispatch(type, payload, from_port) end
  end

  client:connect(host, port, function(err)
    if err then
      if not client:is_closing() then client:close() end
      return
    end
    client:read_start(function(read_err, chunk)
      if read_err or not chunk then return finish() end
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

  if not socket:bind("0.0.0.0", 0, { reuseaddr = true }) then
    socket:close()
    socket = nil
    return nil
  end

  socket:recv_start(function(err, data, addr)
    -- `data == nil` with no error is libuv's "nothing to read", not a message.
    if err or not data or not addr then return end
    local type, value = decode(data)
    if not type then return end
    if type == M.TYPE.Tcp then return fetch_over_tcp(addr.ip, value, addr.port) end
    dispatch(type, value, addr.port)
  end)

  return socket
end

---@param type integer
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

--- Fire and forget: UDP, and Unity does not acknowledge.
---@param instance unity.Instance
---@param type integer
---@param value? string
---@return boolean sent Whether the datagram left, not whether Unity heard it.
function M.send(instance, type, value)
  local sock = ensure_socket()
  if not sock then
    vim.notify("Could not open a UDP socket for Unity", vim.log.levels.ERROR, { title = "Unity" })
    return false
  end
  sock:send(encode(type, value or ""), "127.0.0.1", instance.message_port, function() end)
  return true
end

---@param instance unity.Instance
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

  if not M.send(instance, M.TYPE.Ping) then return done(false) end
  timer:start(timeout or 700, 0, function() vim.schedule(function() done(false) end) end)
end

M.NOT_LISTENING = "Unity is running but its Visual Studio integration is not listening.\n"
  .. "Install the editor shim from <Leader>r and point Unity's External Script Editor at it."

---@param instance unity.Instance
---@param type integer
---@param value? string
---@param on_sent? fun()
function M.send_checked(instance, type, value, on_sent)
  M.ping(instance, function(listening)
    if not listening then
      vim.notify(M.NOT_LISTENING, vim.log.levels.WARN, { title = "Unity" })
      return
    end
    M.send(instance, type, value)
    if on_sent then on_sent() end
  end)
end

return M
