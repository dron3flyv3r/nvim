local M = {}

--- Unity's compile messages are deliberately *not* `vim.diagnostic` entries.
--- They are only ever as fresh as the last compile: an error you have just
--- fixed stays on the line until Unity compiles again, and as virtual text it
--- reads as a live error rather than as history. Worse, in the diagnostic
--- namespace it would also answer `]d` and `<Leader>xd`, so a stale message
--- would follow you around the buffer.
---
--- So they are kept here and shown only when asked for -- the statusline count
--- says how many there are, and the list says what they were.
---@type table<string, table[]>
local by_file = {}

---@param message string
---@return string text
---@return string|nil code
local function split_message(message)
  -- `Assets/Foo.cs(12,5): error CS0103: The name 'x' does not exist ...`.
  -- Unity repeats the position and the severity in the text; the list column
  -- already carries the position, and the `E`/`W` marker the severity.
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

--- Take the bridge's `diagnostics.json` and remember what it says.
---@param root string
---@param decoded table|nil The decoded file, or nil when there is none.
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
      -- the same error can arrive several times over.
      local duplicate = false
      for _, existing in ipairs(by_file[path]) do
        if existing.lnum == line and existing.col == column and existing.text == text then
          duplicate = true
          break
        end
      end

      if not duplicate then
        table.insert(by_file[path], {
          lnum = line,
          col = column,
          text = text,
          code = code,
          type = is_error and "E" or "W",
        })
        counts[is_error and "errors" or "warnings"] = counts[is_error and "errors" or "warnings"] + 1
      end
    end
  end

  return counts
end

--- Every message the last compile produced -- including the ones in files that
--- are not open, which is most of them after a bad compile. The code is kept
--- apart from the text so the list can colour it the way a diagnostic is.
---@param include_warnings? boolean
---@return table[]
function M.list(include_warnings)
  local items = {}
  for path, messages in pairs(by_file) do
    for _, message in ipairs(messages) do
      if include_warnings or message.type == "E" then
        table.insert(items, {
          filename = path,
          lnum = message.lnum,
          col = message.col,
          type = message.type,
          code = message.code,
          text = message.text,
        })
      end
    end
  end

  -- By file and then down the file: the order you would fix them in.
  table.sort(items, function(a, b)
    if a.filename ~= b.filename then return a.filename < b.filename end
    if a.lnum ~= b.lnum then return a.lnum < b.lnum end
    return a.col < b.col
  end)
  return items
end

--- Drop everything. For uninstalling the bridge, or leaving the project.
function M.clear() by_file = {} end

return M
