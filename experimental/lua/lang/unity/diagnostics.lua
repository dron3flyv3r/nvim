local M = {}

--- Unity's compile messages are deliberately not `vim.diagnostic` entries.
--- They are only ever as fresh as the last compile: an error you have just
--- fixed stays on the line until Unity compiles again, and in the diagnostic
--- namespace it would answer `]d` and follow you around the buffer as if it
--- were live.
---@type table<string, unity.Diagnostic[]>
local by_file = {}

---@param message string
---@return string text
---@return string|nil code
local function split_message(message)
  -- `Assets/Foo.cs(12,5): error CS0103: The name 'x' does not exist`. The
  -- position and severity are already columns in the list.
  local stripped = message:gsub("^[^%(]*%(%d+,%d+%):%s*", "")
  local code, rest = stripped:match "^%a+%s+(%u+%d+):%s*(.*)$"
  if code then return rest, code end
  return stripped, nil
end

---@param root string
---@param file string As Unity wrote it: relative to the project, or absolute.
---@return string
local function absolute(root, file)
  if file == "" then return "" end
  return vim.startswith(file, "/") and file or (root .. "/" .. file)
end

---@param root string
---@param decoded table|nil
---@return { errors: integer, warnings: integer }
function M.record(root, decoded)
  local counts = { errors = 0, warnings = 0 }
  by_file = {}

  for _, item in ipairs(decoded and decoded.items or {}) do
    local path = absolute(root, item.file or "")
    local line = math.max(1, tonumber(item.line) or 1)
    local column = math.max(1, tonumber(item.column) or 1)
    local text, code = split_message(item.message or "")
    local is_error = item.severity ~= "warning"

    if path ~= "" then
      path = vim.fn.resolve(path)
      by_file[path] = by_file[path] or {}

      -- Unity reports a file's messages once per assembly that compiles it, so
      -- the same error arrives several times over.
      local duplicate = false
      for _, existing in ipairs(by_file[path]) do
        if existing.lnum == line and existing.col == column and existing.text == text then
          duplicate = true
          break
        end
      end

      if not duplicate then
        table.insert(by_file[path], {
          filename = path,
          lnum = line,
          col = column,
          text = text,
          code = code or "",
          type = is_error and "E" or "W",
        })
        local key = is_error and "errors" or "warnings"
        counts[key] = counts[key] + 1
      end
    end
  end

  return counts
end

---@param include_warnings? boolean
---@return unity.Diagnostic[]
function M.list(include_warnings)
  local items = {}
  for _, messages in pairs(by_file) do
    for _, message in ipairs(messages) do
      if include_warnings or message.type == "E" then table.insert(items, message) end
    end
  end

  table.sort(items, function(a, b)
    if a.filename ~= b.filename then return a.filename < b.filename end
    if a.lnum ~= b.lnum then return a.lnum < b.lnum end
    return a.col < b.col
  end)
  return items
end

function M.clear() by_file = {} end

return M
