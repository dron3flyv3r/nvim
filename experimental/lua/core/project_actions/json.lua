local M = {}

---@class core.project_actions.Node
---@field kind "object"|"array"|"string"|"number"|"boolean"|"null"
---@field value? string|number|boolean
---@field s integer 1-based byte offset of the first character
---@field e integer 1-based byte offset one past the last character
---@field entries? { key: core.project_actions.Node, value: core.project_actions.Node }[]
---@field items? core.project_actions.Node[]

---@class core.project_actions.SyntaxError
---@field offset integer
---@field message string

local ESCAPES = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
local LITERALS = { ["true"] = true, ["false"] = false, null = vim.NIL }

---@param text string
---@return core.project_actions.Node?
---@return core.project_actions.SyntaxError?
function M.parse(text)
  local pos = 1

  local function fail(message, at) error({ offset = at or pos, message = message }, 0) end
  local function skip() pos = text:find("[^ \t\r\n]", pos) or #text + 1 end
  local function peek() return text:sub(pos, pos) end

  local value

  local function string_node()
    local s, parts = pos, {}
    pos = pos + 1
    while true do
      local stop = text:find('["\\%c]', pos)
      if not stop then fail("This string is never closed", s) end
      parts[#parts + 1] = text:sub(pos, stop - 1)
      local c = text:sub(stop, stop)
      if c == '"' then
        pos = stop + 1
        return { kind = "string", value = table.concat(parts), s = s, e = pos }
      elseif c == "\n" then
        fail("This string is never closed", s)
      elseif c ~= "\\" then
        fail("A control character inside a string must be escaped", stop)
      end
      local escape = text:sub(stop + 1, stop + 1)
      if escape == "u" then
        local hex = text:sub(stop + 2, stop + 5)
        if not hex:match "^%x%x%x%x$" then fail("\\u takes four hex digits", stop) end
        parts[#parts + 1] = vim.fn.nr2char(tonumber(hex, 16))
        pos = stop + 6
      elseif ESCAPES[escape] then
        parts[#parts + 1] = ESCAPES[escape]
        pos = stop + 2
      else
        fail(("\\%s is not a JSON escape"):format(escape), stop)
      end
    end
  end

  ---@param close string
  ---@param each fun()
  ---@return integer start
  local function members(close, each)
    local s = pos
    pos = pos + 1
    skip()
    if peek() == close then
      pos = pos + 1
      return s
    end
    while true do
      each()
      skip()
      local c = peek()
      if c == close then
        pos = pos + 1
        return s
      end
      if c == "" then fail(("Expected '%s' before the end of the file"):format(close)) end
      if c ~= "," then fail(("Expected ',' or '%s'"):format(close)) end
      local comma = pos
      pos = pos + 1
      skip()
      if peek() == close then fail("JSON allows no comma before " .. close, comma) end
    end
  end

  local function object_node()
    local node = { kind = "object", entries = {} }
    node.s = members("}", function()
      if peek() ~= '"' then fail "Expected a quoted key" end
      local key = string_node()
      skip()
      if peek() ~= ":" then fail "Expected ':' after the key" end
      pos = pos + 1
      skip()
      node.entries[#node.entries + 1] = { key = key, value = value() }
    end)
    node.e = pos
    return node
  end

  local function array_node()
    local node = { kind = "array", items = {} }
    node.s = members("]", function() node.items[#node.items + 1] = value() end)
    node.e = pos
    return node
  end

  value = function()
    local c = peek()
    if c == "{" then return object_node() end
    if c == "[" then return array_node() end
    if c == '"' then return string_node() end
    local s = pos
    local number = text:match("^-?%d+%.?%d*[eE][-+]?%d+", pos) or text:match("^-?%d+%.?%d*", pos)
    if number then
      pos = pos + #number
      return { kind = "number", value = tonumber(number), s = s, e = pos }
    end
    local word = text:match("^%a+", pos)
    if word and LITERALS[word] ~= nil then
      pos = pos + #word
      return { kind = word == "null" and "null" or "boolean", value = LITERALS[word], s = s, e = pos }
    end
    if c == "" then fail "The file ends where a value should be" end
    if word then fail(("%s is not a JSON value; strings are quoted"):format(word)) end
    fail(("Unexpected %q"):format(c))
  end

  local ok, result = pcall(function()
    skip()
    local root = value()
    skip()
    if pos <= #text then fail "Unexpected text after the end of the document" end
    return root
  end)
  if ok then return result end
  if type(result) ~= "table" then error(result, 0) end
  return nil, result
end

---@param text string
---@return integer[] starts the offset each line begins at
function M.lines(text)
  local starts = { 1 }
  for newline in text:gmatch "()\n" do
    starts[#starts + 1] = newline + 1
  end
  return starts
end

---@param starts integer[]
---@param offset integer
---@return lsp.Position
function M.position(starts, offset)
  local lo, hi = 1, #starts
  while lo < hi do
    local mid = math.floor((lo + hi + 1) / 2)
    if starts[mid] <= offset then
      lo = mid
    else
      hi = mid - 1
    end
  end
  return { line = lo - 1, character = offset - starts[lo] }
end

---@param starts integer[]
---@param position lsp.Position
---@return integer
function M.offset(starts, position)
  local start = starts[position.line + 1] or starts[#starts]
  return start + position.character
end

return M
