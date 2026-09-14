local M = {}

local BLOCK_GAP = 400

local PATTERN = "^([%w_%-%./ ]+%.cs)%((%d+),(%d+)%):%s+(%a+)%s+(%u+%d+):%s*(.*)$"

---@param root string
---@param include_warnings? boolean
---@return table[] items Messages, in the order Unity printed them.
function M.diagnostics(root, include_warnings)
  local log = require("user.integrations.unity").log_file()
  local file = io.open(log, "r")
  if not file then return {} end

  local block, seen, previous = {}, {}, nil
  local number = 0
  for line in file:lines() do
    number = number + 1
    local path, lnum, col, severity, code, message = line:match(PATTERN)
    if path and (severity == "error" or severity == "warning") then
      if previous and number - previous > BLOCK_GAP then
        -- A new compile. Everything collected so far is history.
        block, seen = {}, {}
      end
      previous = number

      -- Unity prints each diagnostic several times per compile; the file, the
      -- position and the code together identify it.
      local key = ("%s:%s:%s:%s"):format(path, lnum, col, code)
      if not seen[key] then
        seen[key] = true
        table.insert(block, {
          -- The path is relative to the project root, and a list entry is
          -- resolved against the cwd -- which is not necessarily the same
          -- place. Absolute, so the entry is jumpable from anywhere.
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

--- Unity's messages in the shape snacks' own diagnostics picker uses, so the
--- list reads the way `<Leader>xx` does -- severity icon, message, code, file.
---@param items table[]
---@return table[]
local function picker_items(items)
  local out = {}
  for _, item in ipairs(items) do
    local severity = item.type == "W" and vim.diagnostic.severity.WARN or vim.diagnostic.severity.ERROR
    out[#out + 1] = {
      -- What typing in the picker matches against: the filename as you would
      -- think of it, the code, and the message.
      text = table.concat({ vim.fn.fnamemodify(item.filename, ":t"), item.code or "", item.text }, " "),
      file = item.filename,
      -- The picker wants a 1-indexed line and a 0-indexed column; Unity counts
      -- both from one.
      pos = { item.lnum, math.max(0, item.col - 1) },
      severity = severity,
      -- The `diagnostic` formatter reads this as a `vim.Diagnostic` would be.
      item = { message = item.text, source = "Unity", code = item.code },
    }
  end
  return out
end

--- Open Unity's compiler messages in a picker. Deliberately a list and not a
--- jump: these are as old as the last compile, so the first thing you want is
--- to see what there is, not to be thrown into the first one of them.
---@param include_warnings? boolean
function M.errors(include_warnings)
  local unity = require "user.integrations.unity"
  local watched = require("user.integrations.unity.state").get().root
  -- The picker's own buffers have no path, so asking the buffer which project
  -- it belongs to fails the moment this is re-run from inside the list. The
  -- project being watched is the right answer whenever the buffer has none;
  -- `require_root` is left to do the complaining.
  local root = unity.root() or watched or unity.require_root()
  if not root then return end

  local kind = include_warnings and "diagnostic" or "error"

  -- The bridge has the compiler's own messages, with the file, the line and the
  -- column as the compiler reported them. Scraping a 50MB editor log for the
  -- same thing is the fallback for a project that has no bridge installed.
  local items
  if watched == root then
    items = require("user.integrations.unity.diagnostics").list(include_warnings)
  else
    items = M.diagnostics(root, include_warnings)
  end

  if vim.tbl_isempty(items) then
    -- Empty means Unity's last compile was clean, not that the scrape failed --
    -- worth saying, because it is the answer you are usually hoping for.
    vim.notify(("Unity's last compile had no %ss"):format(kind), vim.log.levels.INFO, { title = "Unity" })
    return
  end

  require("snacks").picker {
    title = include_warnings and "Unity compile errors and warnings" or "Unity compile errors",
    items = picker_items(items),
    format = "diagnostic",
    -- Errors before warnings, and then the order they were built in: by file,
    -- and down the file. `sort_empty` is what makes that hold before you type.
    sort = { fields = { "severity", "idx" } },
    matcher = { sort_empty = true },
  }
end

function M.tail()
  local log = require("user.integrations.unity").log_file()
  if vim.fn.filereadable(log) ~= 1 then
    vim.notify(("No editor log at %s"):format(log), vim.log.levels.WARN, { title = "Unity" })
    return
  end
  vim.cmd "botright 15split"
  vim.cmd.terminal(("tail -n 200 -f %s"):format(vim.fn.fnameescape(log)))
  vim.cmd "startinsert"
end

return M
