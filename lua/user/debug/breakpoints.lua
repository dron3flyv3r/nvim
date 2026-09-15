-- Breakpoints as a set you manage, rather than one line at a time.
local M = {}

--- What was turned off, so it can be turned back on. DAP has no notion of a
--- disabled breakpoint -- an adapter only knows the set it was last sent -- so
--- muting is remembering the set, sending an empty one, and restoring later.
local muted = nil

---@param sessions table<integer, table>
---@param fn fun(session: table)
local function broadcast(sessions, fn)
  for _, session in pairs(sessions) do
    fn(session)
    broadcast(session.children, fn)
  end
end

--- Hand every session the set it should be holding, naming the buffers whose
--- breakpoints are gone so that emptying one is an update rather than a silence.
---
--- `dap.breakpoints.get` drops a buffer from its result the moment the last
--- breakpoint in it is gone, and `Session:set_breakpoints` returns without
--- sending anything when it is handed a table with no entries at all. Between
--- them, "there are none left anywhere" -- which is exactly what muting and
--- deleting produce -- never reaches the adapter: the signs disappear, the
--- adapter keeps every breakpoint it was given, and the program goes on stopping
--- at breakpoints that are no longer on screen.
---@param emptied table<integer, boolean>|nil buffers that held breakpoints before the change
local function sync(emptied)
  local points = require("dap.breakpoints").get()
  for bufnr in pairs(emptied or {}) do
    -- A wiped buffer has no name to send the adapter, and nothing left to stop
    -- on either.
    if not points[bufnr] and vim.api.nvim_buf_is_valid(bufnr) then points[bufnr] = {} end
  end
  if not next(points) then return end

  broadcast(require("dap").sessions(), function(session) session:set_breakpoints(points) end)
end

---@param points table<integer, table[]>
---@return table<integer, boolean>
local function buffers(points)
  local held = {}
  for bufnr in pairs(points) do
    held[bufnr] = true
  end
  return held
end

---@param points table<integer, table[]>
---@return integer
local function count(points)
  local total = 0
  for _, per_buffer in pairs(points) do
    total = total + #per_buffer
  end
  return total
end

---@param message string
---@param level integer|nil
local function say(message, level) vim.notify(message, level or vim.log.levels.INFO, { title = "Debug" }) end

--- Every breakpoint at once, in a window you can walk and click.
function M.list()
  require("dapui").float_element("breakpoints", { enter = true, position = "center", width = 100, height = 20 })
end

--- Silence them all without losing them, or give them back.
function M.toggle_mute()
  local breakpoints = require "dap.breakpoints"

  if muted then
    local restored = count(muted)
    for bufnr, points in pairs(muted) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        for _, point in ipairs(points) do
          breakpoints.set({
            condition = point.condition,
            hit_condition = point.hitCondition,
            log_message = point.logMessage,
          }, bufnr, point.line)
        end
      end
    end
    muted = nil
    sync()
    say(("%d breakpoints are live again"):format(restored))
  else
    local points = breakpoints.get()
    local total = count(points)
    if total == 0 then return say "There are no breakpoints to mute" end

    muted = points
    breakpoints.clear()
    sync(buffers(points))
    say(("%d breakpoints muted -- the same key brings them back"):format(total), vim.log.levels.WARN)
  end
end

--- Gone for good.
function M.clear()
  local breakpoints = require "dap.breakpoints"
  local points = breakpoints.get()
  local total = count(points) + count(muted or {})
  if total == 0 then return say "There are no breakpoints to delete" end

  local emptied = buffers(points)
  -- Deleting while muted has to forget the muted set too, or the next unmute
  -- would resurrect everything that was just thrown away -- and the adapter is
  -- still holding those, since muting is the one thing that never told it.
  for bufnr in pairs(muted or {}) do
    emptied[bufnr] = true
  end
  muted = nil

  breakpoints.clear()
  sync(emptied)
  say(("%d breakpoints deleted"):format(total))
end

---@return boolean
function M.is_muted() return muted ~= nil end

return M
