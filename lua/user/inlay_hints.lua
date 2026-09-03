local M = {}
local handler = require "user.inlay_hints.handler"
local matcher = require "user.inlay_hints.matcher"
local store = require "user.inlay_hints.store"
local syntax = require "user.inlay_hints.syntax"

local function notify(message, level) vim.notify(message, level or vim.log.levels.INFO, { title = "Inlay hints" }) end

local function refresh_store()
  store.invalidate()
  matcher.invalidate()
  handler.refresh()
end

---@param global boolean?
---@return user.inlay_hints.Store? data
---@return user.inlay_hints.Bucket? bucket
---@return string? scope
local function target(global)
  local data = store.read()
  if global then return data, data.global, "everywhere" end

  local root = store.root(vim.api.nvim_get_current_buf())
  if not root then
    notify(
      "This buffer is not in a project. Add `!` to the command to hide it everywhere instead.",
      vim.log.levels.WARN
    )
    return nil
  end
  data.projects[root] = data.projects[root] or store.empty_bucket()
  return data, data.projects[root], root
end

local function save(data)
  if not store.write(data) then return false end
  matcher.invalidate()
  handler.refresh()
  return true
end

---@param bucket user.inlay_hints.Bucket
---@param field "callees"|"paths"
---@param value string
---@param data user.inlay_hints.Store
---@param scope string
---@param action string
local function add(bucket, field, value, data, scope, action)
  if vim.tbl_contains(bucket[field], value) then
    notify(value .. " is already ignored")
    return
  end
  bucket[field][#bucket[field] + 1] = value
  if save(data) then notify(("%s %s (%s)"):format(action, value, scope)) end
end

local function callee_under_cursor()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  return syntax.call_at(vim.api.nvim_get_current_buf(), row - 1, col, true)
end

---@param name string?
---@param global boolean?
function M.ignore(name, global)
  if not name or name == "" then
    local full, last = callee_under_cursor()
    name = last or full
    if not name then
      notify("The cursor is not on a call, so there is no name to ignore", vim.log.levels.WARN)
      return
    end
  end

  local data, bucket, scope = target(global)
  if data and bucket and scope then add(bucket, "callees", name, data, scope, "Hiding parameter hints for") end
end

function M.toggle()
  local full, last = callee_under_cursor()
  if not full then
    notify("The cursor is not on a call, so there is no name to toggle", vim.log.levels.WARN)
    return
  end

  local root = store.root(vim.api.nvim_get_current_buf())
  if not root then
    notify("This buffer is not in a project, so its call hints cannot be toggled locally", vim.log.levels.WARN)
    return
  end

  local data = store.read()
  local function matches(value) return value == full or value == last end
  if vim.iter(data.global.callees):any(matches) then
    notify((last or full) .. " is ignored everywhere; use :InlayHintsUnignore to show it again", vim.log.levels.WARN)
    return
  end

  local bucket = data.projects[root]
  if bucket and vim.iter(bucket.callees):any(matches) then
    bucket.callees = vim.tbl_filter(function(value) return not matches(value) end, bucket.callees)
    if save(data) then notify("Showing parameter hints for " .. (last or full) .. " again (" .. root .. ")") end
    return
  end

  data.projects[root] = bucket or store.empty_bucket()
  add(data.projects[root], "callees", last or full, data, root, "Hiding parameter hints for")
end

---@param pattern string?
---@param global boolean?
function M.ignore_file(pattern, global)
  local data, bucket, scope = target(global)
  if not data or not bucket or not scope then return end

  if not pattern or pattern == "" then
    local bufnr = vim.api.nvim_get_current_buf()
    local root = not global and store.root(bufnr) or nil
    local absolute, relative = matcher.paths(bufnr, root)
    pattern = relative or absolute
    if pattern == "" then
      notify("This buffer has no file to ignore", vim.log.levels.WARN)
      return
    end
  end

  add(bucket, "paths", pattern, data, scope, "Hiding inlay hints in")
end

function M.unignore()
  local data = store.read()
  local root = store.root(vim.api.nvim_get_current_buf())
  ---@type { bucket: user.inlay_hints.Bucket, field: string, text: string, scope: string }[]
  local entries = {}
  local function collect(bucket, scope)
    if not bucket then return end
    for _, field in ipairs { "callees", "paths" } do
      for _, value in ipairs(bucket[field]) do
        entries[#entries + 1] = { bucket = bucket, field = field, text = value, scope = scope }
      end
    end
  end
  collect(root and data.projects[root], "project")
  collect(data.global, "global")

  if #entries == 0 then
    notify "Nothing is ignored here"
    return
  end

  vim.ui.select(entries, {
    prompt = "Show inlay hints again for:",
    format_item = function(entry)
      return ("%-7s %-7s %s"):format(entry.scope, entry.field == "callees" and "callee" or "path", entry.text)
    end,
  }, function(choice)
    if not choice then return end
    choice.bucket[choice.field] = vim.tbl_filter(
      function(value) return value ~= choice.text end,
      choice.bucket[choice.field]
    )
    if save(data) then notify("Showing inlay hints for " .. choice.text .. " again") end
  end)
end

function M.ignored()
  local data = store.read()
  local root = store.root(vim.api.nvim_get_current_buf())
  local lines = { store.path }
  local function section(heading, bucket)
    if not bucket or (#bucket.callees == 0 and #bucket.paths == 0) then return end
    lines[#lines + 1] = heading
    for _, field in ipairs { "callees", "paths" } do
      if #bucket[field] > 0 then
        lines[#lines + 1] = "    " .. field .. ":"
        local sorted = vim.deepcopy(bucket[field])
        table.sort(sorted)
        for _, entry in ipairs(sorted) do
          lines[#lines + 1] = "      " .. entry
        end
      end
    end
  end
  section("  global:", data.global)
  section("  " .. (root or "(no project)") .. ":", root and data.projects[root])
  if #lines == 1 then lines[#lines + 1] = "  (nothing ignored)" end
  notify(table.concat(lines, "\n"))
end

function M.edit()
  vim.cmd.edit(vim.fn.fnameescape(store.path))
  if vim.uv.fs_stat(store.path) == nil then
    vim.api.nvim_buf_set_lines(0, 0, -1, false, {
      "{",
      '  "global": {',
      '    "callees": [],',
      '    "paths": []',
      "  },",
      '  "projects": {}',
      "}",
    })
  end
  vim.api.nvim_create_autocmd("BufWritePost", {
    buffer = vim.api.nvim_get_current_buf(),
    desc = "Apply the edited inlay hint ignore list",
    callback = refresh_store,
  })
end

M.filter = handler.filter
M.refresh = handler.refresh
M.setup = handler.setup

return M
