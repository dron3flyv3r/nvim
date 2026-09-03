local M = {}

local BLOCK_GAP = 400

local PATTERN = "^([%w_%-%./ ]+%.cs)%((%d+),(%d+)%):%s+(%a+)%s+(%u+%d+):%s*(.*)$"

---@param root string
---@param include_warnings? boolean
---@return table[] items Quickfix items, in the order Unity printed them.
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
          -- The path is relative to the project root, and a quickfix entry is
          -- resolved against the cwd -- which is not necessarily the same
          -- place. Absolute, so the entry is jumpable from anywhere.
          filename = vim.startswith(path, "/") and path or (root .. "/" .. path),
          lnum = tonumber(lnum),
          col = tonumber(col),
          type = severity == "error" and "E" or "W",
          text = ("%s: %s"):format(code, message),
          severity = severity,
        })
      end
    end
  end
  file:close()

  if include_warnings then return block end
  return vim.tbl_filter(function(item) return item.severity == "error" end, block)
end

--- Load Unity's compiler diagnostics into the quickfix list.
---@param include_warnings? boolean
function M.errors(include_warnings)
  local root = require("user.integrations.unity").require_root()
  if not root then return end

  local kind = include_warnings and "diagnostic" or "error"
  local items = M.diagnostics(root, include_warnings)

  if vim.tbl_isempty(items) then
    -- Empty means Unity's last compile was clean, not that the scrape failed --
    -- worth saying, because it is the answer you are usually hoping for.
    vim.notify(("Unity's last compile had no %ss"):format(kind), vim.log.levels.INFO, { title = "Unity" })
    vim.fn.setqflist({}, " ", { title = "Unity compile", items = {} })
    return
  end

  vim.fn.setqflist({}, " ", { title = "Unity compile", items = items })
  vim.notify(
    ("%d Unity %s%s in the quickfix list (æq / øq)"):format(#items, kind, #items == 1 and "" or "s"),
    vim.log.levels.WARN,
    { title = "Unity" }
  )
  vim.cmd.cfirst()
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
