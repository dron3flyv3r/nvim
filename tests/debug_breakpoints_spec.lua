-- Muting and deleting have to reach the adapter. The bug this guards against
-- was silent: the signs went away, nvim sent nothing, and the program kept
-- stopping at breakpoints that were no longer on screen.
local saved = {
  dap = package.loaded["dap"],
  breakpoints = package.loaded["dap.breakpoints"],
  module = package.loaded["user.debug.breakpoints"],
  notify = vim.notify,
}

local placed = {}
local sent = {}

--- The two nvim-dap behaviours that made the bug possible, kept exactly:
--- `get()` forgets a buffer the moment its last breakpoint is gone, and a
--- session ignores a set that names no buffer at all.
local fake_breakpoints = {
  get = function(bufnr)
    if bufnr then return { [bufnr] = vim.deepcopy(placed[bufnr] or {}) } end
    local all = {}
    for buf, points in pairs(placed) do
      if #points > 0 then all[buf] = vim.deepcopy(points) end
    end
    return all
  end,
  set = function(_, bufnr, line)
    placed[bufnr] = placed[bufnr] or {}
    table.insert(placed[bufnr], { line = line })
  end,
  clear = function() placed = {} end,
}

local fake_session = {
  children = {},
  set_breakpoints = function(_, points)
    if next(points) == nil then return end
    table.insert(sent, vim.deepcopy(points))
  end,
}

package.loaded["dap.breakpoints"] = fake_breakpoints
package.loaded["dap"] = { sessions = function() return { fake_session } end }
package.loaded["user.debug.breakpoints"] = nil
vim.notify = function() end

local module = require "user.debug.breakpoints"
local one = vim.api.nvim_create_buf(false, true)
local two = vim.api.nvim_create_buf(false, true)

---@param message string
local function check(ok, message)
  if not ok then error("debug breakpoints spec: " .. message, 0) end
end

---@param bufnr integer
---@param message string
local function sent_empty_for(bufnr, message)
  local last = sent[#sent]
  check(last ~= nil, message .. ": nothing was sent at all")
  check(last[bufnr] ~= nil, message .. ": the buffer was not named")
  check(#last[bufnr] == 0, message .. ": the buffer was not emptied")
end

fake_breakpoints.set({}, one, 10)
fake_breakpoints.set({}, two, 4)

module.toggle_mute()
sent_empty_for(one, "muting")
sent_empty_for(two, "muting")
check(module.is_muted(), "muting should be remembered")

module.toggle_mute()
local restored = sent[#sent]
check(#restored[one] == 1 and restored[one][1].line == 10, "unmuting should put the breakpoint back")
check(#restored[two] == 1, "unmuting should restore every buffer")
check(not module.is_muted(), "unmuting should be forgotten")

module.clear()
sent_empty_for(one, "deleting")
sent_empty_for(two, "deleting")

-- Deleting while muted is the case that used to leave the adapter holding a set
-- nvim had already thrown away: the mute never reached it either.
fake_breakpoints.set({}, one, 10)
module.toggle_mute()
local before = #sent
module.clear()
check(#sent > before, "deleting while muted should still send")
sent_empty_for(one, "deleting while muted")
check(not module.is_muted(), "deleting should forget the muted set")

vim.notify = saved.notify
package.loaded["dap"] = saved.dap
package.loaded["dap.breakpoints"] = saved.breakpoints
package.loaded["user.debug.breakpoints"] = saved.module
