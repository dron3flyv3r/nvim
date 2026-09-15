-- Breakpoints as a set you manage, rather than one line at a time.
local M = {}

--- What was turned off, so it can be turned back on. DAP has no notion of a
--- disabled breakpoint -- an adapter only knows the set it was last sent -- so
--- muting is remembering the set, sending an empty one, and restoring later.
local muted = nil

local function sync()
  local points = require("dap.breakpoints").get()
  for _, session in pairs(require("dap").sessions()) do
    session:set_breakpoints(points)
  end
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
    say(("%d breakpoints are live again"):format(restored))
  else
    local points = breakpoints.get()
    local total = count(points)
    if total == 0 then return say "There are no breakpoints to mute" end

    muted = points
    breakpoints.clear()
    say(("%d breakpoints muted -- the same key brings them back"):format(total), vim.log.levels.WARN)
  end

  sync()
end

--- Gone for good.
function M.clear()
  local total = count(require("dap.breakpoints").get())
  if total == 0 and not muted then return say "There are no breakpoints to delete" end

  require("dap").clear_breakpoints()
  -- Deleting while muted has to forget the muted set too, or the next unmute
  -- would resurrect everything that was just thrown away.
  muted = nil
  say(("%d breakpoints deleted"):format(total))
end

---@return boolean
function M.is_muted() return muted ~= nil end

return M
