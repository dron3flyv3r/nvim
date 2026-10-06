local M = {}

---@class plugins.analysis.Response
---@field ok boolean
---@field status? integer
---@field body? table
---@field err? string

---@param result vim.SystemCompleted
---@return plugins.analysis.Response
local function parse(result)
  if result.code ~= 0 then return { ok = false, err = vim.trim(result.stderr or "") } end
  local text, status = (result.stdout or ""):match "^(.*)\n(%d+)$"
  status = tonumber(status)
  if not status or status == 0 then return { ok = false, err = "no answer" } end
  local decoded, body = pcall(vim.json.decode, text or "", { luanil = { object = true, array = true } })
  body = decoded and type(body) == "table" and body or nil
  if status == 401 or status == 403 then
    return { ok = false, status = status, err = "the server rejected the token" }
  end
  if status >= 400 then
    local message = body and body.errors and body.errors[1] and body.errors[1].msg
    return { ok = false, status = status, err = message or ("HTTP " .. status) }
  end
  if not body then return { ok = false, status = status, err = "the server did not answer as SonarQube" } end
  return { ok = true, status = status, body = body }
end

---@param path string
---@param query table<string, string|integer>
---@return string
local function url_for(path, query)
  local params = {}
  for key, value in pairs(query) do
    params[#params + 1] = key .. "=" .. vim.uri_encode(tostring(value), "rfc3986")
  end
  table.sort(params)
  local base = require("plugins.code-analysis.control").device().url:gsub("/+$", "")
  return base .. "/" .. path .. (#params > 0 and ("?" .. table.concat(params, "&")) or "")
end

-- The token goes to curl on stdin so it never appears in the process list.
---@param path string
---@param query table<string, string|integer>
---@param on_done fun(response: plugins.analysis.Response)
function M.get(path, query, on_done)
  local config = ('url = "%s"\n'):format(url_for(path, query))
  local token = require("plugins.code-analysis.control").token()
  if token then config = config .. ('user = "%s:"\n'):format(token) end
  local ok = pcall(
    vim.system,
    { "curl", "-sS", "--max-time", "15", "-w", "\n%{http_code}", "-K", "-" },
    { stdin = config, text = true },
    function(result)
      vim.schedule(function() on_done(parse(result)) end)
    end
  )
  if not ok then vim.schedule(function() on_done { ok = false, err = "curl is not installed" } end) end
end

---@param path string
---@param query table<string, string|integer>
---@return plugins.analysis.Response
function M.wait(path, query)
  local response
  M.get(path, query, function(result) response = result end)
  vim.wait(20000, function() return response ~= nil end, 50)
  return response or { ok = false, err = "timed out" }
end

---@param path string
---@param query table<string, string|integer>
---@return plugins.analysis.Response
function M.await(path, query)
  local co = coroutine.running()
  M.get(path, query, function(result) coroutine.resume(co, result) end)
  return coroutine.yield()
end

---@param requests { [1]: string, [2]: table<string, string|integer> }[]
---@param width? integer
---@return plugins.analysis.Response[]
function M.await_all(requests, width)
  local co = coroutine.running()
  local results = {}
  width = width or 8
  for first = 1, #requests, width do
    local last = math.min(first + width - 1, #requests)
    local pending = last - first + 1
    for index = first, last do
      M.get(requests[index][1], requests[index][2], function(result)
        results[index] = result
        pending = pending - 1
        if pending == 0 then coroutine.resume(co) end
      end)
    end
    coroutine.yield()
  end
  return results
end

return M
