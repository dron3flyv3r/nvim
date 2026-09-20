local project = require "lang.unity.project"

local M = {}

local BLOCK_GAP = 400

local PATTERN = "^([%w_%-%./ ]+%.cs)%((%d+),(%d+)%):%s+(%a+)%s+(%u+%d+):%s*(.*)$"

---@class unity.Diagnostic
---@field filename string
---@field lnum integer
---@field col integer
---@field type "E"|"W"
---@field code string
---@field text string

---@param root string
---@param include_warnings? boolean
---@return unity.Diagnostic[]
function M.diagnostics(root, include_warnings)
  local file = io.open(project.log_file(), "r")
  if not file then return {} end

  local block, seen, previous = {}, {}, nil
  local number = 0
  for line in file:lines() do
    number = number + 1
    local path, lnum, col, severity, code, message = line:match(PATTERN)
    if path and (severity == "error" or severity == "warning") then
      -- A gap this large means a later compile started; what came before is
      -- history and must not be mixed into this list.
      if previous and number - previous > BLOCK_GAP then block, seen = {}, {} end
      previous = number

      local key = ("%s:%s:%s:%s"):format(path, lnum, col, code)
      if not seen[key] then
        seen[key] = true
        table.insert(block, {
          -- Unity prints paths relative to the project, and a list entry is
          -- resolved against the cwd, which is not necessarily the same place.
          filename = vim.startswith(path, "/") and path or (root .. "/" .. path),
          lnum = tonumber(lnum),
          col = tonumber(col),
          type = severity == "error" and "E" or "W",
          code = code,
          text = message,
        })
      end
    end
  end
  file:close()

  if include_warnings then return block end
  return vim.tbl_filter(function(item) return item.type == "E" end, block)
end

---@param items unity.Diagnostic[]
---@return snacks.picker.finder.Item[]
local function picker_items(items)
  local out = {}
  for _, item in ipairs(items) do
    out[#out + 1] = {
      text = table.concat({ vim.fs.basename(item.filename), item.code, item.text }, " "),
      file = item.filename,
      pos = { item.lnum, math.max(0, item.col - 1) },
      severity = item.type == "W" and vim.diagnostic.severity.WARN or vim.diagnostic.severity.ERROR,
      item = { message = item.text, source = "Unity", code = item.code },
    }
  end
  return out
end

---@param include_warnings? boolean
function M.errors(include_warnings)
  local watched = require("lang.unity.state").get()
  -- The picker's own buffers have no path, so asking the buffer which project
  -- it belongs to fails the moment this is re-run from inside the list.
  local root = project.root() or watched.root or project.require_root()
  if not root then return end

  -- The bridge has the compiler's own messages, with the positions the
  -- compiler reported. Scraping a 50MB editor log is the fallback for a
  -- project that has no bridge installed.
  local items
  if watched.root == root and watched.installed then
    items = require("lang.unity.diagnostics").list(include_warnings)
  else
    items = M.diagnostics(root, include_warnings)
  end
  if vim.tbl_isempty(items) then
    vim.notify(
      ("Unity's last compile had no %ss"):format(include_warnings and "diagnostic" or "error"),
      vim.log.levels.INFO,
      { title = "Unity" }
    )
    return
  end

  require("snacks").picker {
    title = include_warnings and "Unity compile errors and warnings" or "Unity compile errors",
    items = picker_items(items),
    format = "diagnostic",
    sort = { fields = { "severity", "idx" } },
    matcher = { sort_empty = true },
  }
end

function M.tail()
  local log = project.log_file()
  if vim.fn.filereadable(log) ~= 1 then
    vim.notify(("No editor log at %s"):format(log), vim.log.levels.WARN, { title = "Unity" })
    return
  end
  require("core.task").run {
    name = "unity editor log",
    cmd = { "tail", "-n", "200", "-f", log },
    queue = false,
  }
end

return M
