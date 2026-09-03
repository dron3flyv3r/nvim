local M = {}

M.path = vim.fs.joinpath(vim.fn.stdpath "data" --[[@as string]], "inlay-hints.json")
local ROOT_MARKERS = { ".git", ".hg", ".svn" }
local cache ---@type { mtime: integer, data: user.inlay_hints.Store }?

---@class user.inlay_hints.Bucket
---@field callees string[]
---@field paths string[]

---@class user.inlay_hints.Store
---@field global user.inlay_hints.Bucket
---@field projects table<string, user.inlay_hints.Bucket>

---@return user.inlay_hints.Bucket
function M.empty_bucket() return { callees = {}, paths = {} } end

---@param value any
---@return user.inlay_hints.Bucket
function M.bucket(value)
  local bucket = M.empty_bucket()
  if type(value) ~= "table" then return bucket end
  for _, field in ipairs { "callees", "paths" } do
    for _, entry in ipairs(value[field] or {}) do
      if type(entry) == "string" and entry ~= "" then table.insert(bucket[field], entry) end
    end
  end
  return bucket
end

---@param bufnr integer
---@return string?
function M.root(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" or name:find "://" then return nil end
  local root = vim.fs.root(bufnr, ROOT_MARKERS)
  return root and vim.fs.normalize(root) or nil
end

function M.invalidate() cache = nil end

---@return user.inlay_hints.Store
function M.read()
  local stat = vim.uv.fs_stat(M.path)
  local mtime = stat and stat.mtime.sec or 0
  if cache and cache.mtime == mtime then return cache.data end

  ---@type user.inlay_hints.Store
  local data = { global = M.empty_bucket(), projects = {} }
  local file = stat and io.open(M.path, "r")
  if file then
    local text = file:read "a"
    file:close()
    local ok, decoded = pcall(vim.json.decode, text)
    if not ok or type(decoded) ~= "table" then
      vim.notify(
        M.path .. " is not valid JSON, so no hints are being filtered:\n" .. tostring(decoded),
        vim.log.levels.WARN,
        { title = "Inlay hints" }
      )
    else
      data.global = M.bucket(decoded.global)
      if type(decoded.projects) == "table" then
        for root, bucket in pairs(decoded.projects) do
          if type(root) == "string" then data.projects[vim.fs.normalize(root)] = M.bucket(bucket) end
        end
      end
    end
  end

  cache = { mtime = mtime, data = data }
  return data
end

local function array(values, indent)
  if #values == 0 then return "[]" end
  local sorted = vim.deepcopy(values)
  table.sort(sorted)
  local items = vim.tbl_map(function(value) return indent .. "  " .. vim.json.encode(value) end, sorted)
  return "[\n" .. table.concat(items, ",\n") .. "\n" .. indent .. "]"
end

local function bucket(value, indent)
  return table.concat({
    "{",
    indent .. '  "callees": ' .. array(value.callees, indent .. "  ") .. ",",
    indent .. '  "paths": ' .. array(value.paths, indent .. "  "),
    indent .. "}",
  }, "\n")
end

---@param data user.inlay_hints.Store
---@return boolean
function M.write(data)
  local roots = {}
  for root, value in pairs(data.projects) do
    if #value.callees > 0 or #value.paths > 0 then roots[#roots + 1] = root end
  end
  table.sort(roots)

  local projects = {}
  for _, root in ipairs(roots) do
    projects[#projects + 1] = "    " .. vim.json.encode(root) .. ": " .. bucket(data.projects[root], "    ")
  end

  local text = table.concat({
    "{",
    '  "global": ' .. bucket(data.global, "  ") .. ",",
    '  "projects": ' .. (#projects == 0 and "{}" or "{\n" .. table.concat(projects, ",\n") .. "\n  }"),
    "}",
    "",
  }, "\n")

  vim.fn.mkdir(vim.fs.dirname(M.path), "p")
  local file = io.open(M.path, "w")
  if not file then
    vim.notify("Could not write " .. M.path, vim.log.levels.ERROR, { title = "Inlay hints" })
    return false
  end
  file:write(text)
  file:close()
  M.invalidate()
  return true
end

return M
