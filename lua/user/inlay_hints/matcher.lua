local M = {}
local store = require "user.inlay_hints.store"
local GLOBAL = "\0"
local cache ---@type { mtime: integer, rules: table<string, user.inlay_hints.Rules> }?

---@class user.inlay_hints.Rules
---@field callees table<string, true>
---@field paths { text: string, glob: vim.lpeg.Pattern? }[]
---@field empty boolean

function M.invalidate() cache = nil end

---@param root string?
---@return user.inlay_hints.Rules
function M.rules(root)
  local stat = vim.uv.fs_stat(store.path)
  local mtime = stat and stat.mtime.sec or 0
  if not cache or cache.mtime ~= mtime then cache = { mtime = mtime, rules = {} } end

  local key = root or GLOBAL
  if cache.rules[key] then return cache.rules[key] end

  local data = store.read()
  ---@type user.inlay_hints.Rules
  local rules = { callees = {}, paths = {}, empty = true }
  for _, source in ipairs { data.global, root and data.projects[root] or nil } do
    for _, name in ipairs(source.callees) do
      rules.callees[name] = true
    end
    for _, pattern in ipairs(source.paths) do
      local entry = { text = pattern }
      if pattern:find "[%*%?%[{]" then
        local ok, compiled = pcall(vim.glob.to_lpeg, pattern)
        if ok then
          entry.glob = compiled
        else
          vim.notify(
            ("Ignoring the unparseable path pattern %q"):format(pattern),
            vim.log.levels.WARN,
            { title = "Inlay hints" }
          )
          entry = nil
        end
      end
      if entry then rules.paths[#rules.paths + 1] = entry end
    end
  end
  rules.empty = next(rules.callees) == nil and #rules.paths == 0
  cache.rules[key] = rules
  return rules
end

---@param bufnr integer
---@param root string?
---@return string absolute
---@return string? relative
function M.paths(bufnr, root)
  local absolute = vim.fs.normalize(vim.api.nvim_buf_get_name(bufnr))
  return absolute, root and vim.fs.relpath(root, absolute) or nil
end

---@param rules user.inlay_hints.Rules
---@param absolute string
---@param relative string?
---@return boolean
function M.path_ignored(rules, absolute, relative)
  local candidates = { absolute }
  if relative then table.insert(candidates, 1, relative) end
  for _, entry in ipairs(rules.paths) do
    for _, candidate in ipairs(candidates) do
      if entry.glob then
        if vim.lpeg.match(entry.glob, candidate) then return true end
      elseif candidate == entry.text or candidate:sub(1, #entry.text + 1) == entry.text .. "/" then
        return true
      end
    end
  end
  return false
end

return M
