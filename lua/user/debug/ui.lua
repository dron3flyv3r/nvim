-- Two docks, split by what their panes are for. A panel down the left side
-- holds the state you read -- breakpoints, stack, scopes, watches -- and a dock
-- across the bottom carries the two things that scroll, the REPL and the device
-- log.
--
-- The panel is the visible answer to "is a debugger attached": it opens on
-- attach and goes on stop. The dock outlives it, because a device log is worth
-- reading with no session at all.
--
-- Layout order is load-bearing. `dapui.open` builds layouts from the highest
-- index downwards and whichever is built last takes the corner, so the panel is
-- numbered above every dock to leave the bottom its full width.
local M = {}

local LOG_ONLY, SESSION, SESSION_WITH_LOG, PANEL = 1, 2, 3, 4

--- Four stacked panes need a full-height terminal, and the code beside them
--- still has to be readable. Under this the panel is skipped and the dock goes
--- back to carrying everything itself.
local MIN_COLUMNS = 150

--- Wider than dap-ui's stock 40: `this._feet.position` inside a `Transform`
--- inside a `PlayerController` runs off the edge of a narrow panel long before
--- it runs out of interesting members.
local PANEL_WIDTH = 55

--- The panel's panes, top to bottom, as shares of its height. Kept here rather
--- than inline because the sizes have to be re-applied by hand after opening.
local PANEL_ELEMENTS = {
  { id = "breakpoints", size = 0.15 },
  { id = "stacks", size = 0.20 },
  { id = "scopes", size = 0.40 },
  { id = "watches", size = 0.25 },
}

---@return boolean
local function roomy() return vim.o.columns >= MIN_COLUMNS end

--- The dock's fallback shape on a terminal too narrow for a panel: the old
--- everything-across-the-bottom, where `watches` is the one to drop because it
--- is the only element reachable another way.
---@return table[]
local function crowded_session()
  return {
    { id = "scopes", size = 0.40 },
    { id = "stacks", size = 0.26 },
    { id = "repl", size = 0.34 },
  }
end

---@return table[]
local function crowded_session_with_log()
  return {
    { id = "scopes", size = 0.32 },
    { id = "stacks", size = 0.20 },
    { id = "repl", size = 0.24 },
    { id = "logcat", size = 0.24 },
  }
end

---@return table[]
function M.layouts()
  local session, session_with_log
  if roomy() then
    session = { { id = "repl", size = 1.0 } }
    session_with_log = { { id = "repl", size = 0.5 }, { id = "logcat", size = 0.5 } }
  else
    session, session_with_log = crowded_session(), crowded_session_with_log()
  end

  return {
    [LOG_ONLY] = { position = "bottom", size = 12, elements = { { id = "logcat", size = 1.0 } } },
    [SESSION] = { position = "bottom", size = 14, elements = session },
    [SESSION_WITH_LOG] = { position = "bottom", size = 14, elements = session_with_log },
    [PANEL] = { position = "left", size = PANEL_WIDTH, elements = PANEL_ELEMENTS },
  }
end

--- Which elements ended up somewhere on screen. Anything not among them has to
--- be reached another way, or adding to it looks like nothing happening at all.
local docked = {}

---@param id string
---@return boolean
function M.shows(id) return docked[id] == true end

--- What is on screen now: which dock, if any, and whether the panel is beside
--- it.
local dock = nil ---@type integer|nil
local panel = false

--- Whether a debugger is attached. Not whether it is stopped: the panel is how
--- you know a session is live, so it follows the session rather than the
--- breakpoint.
local attached = false

--- Whether this terminal was wide enough for a panel when the layouts were
--- built. `dapui.setup` tears down every window it owns, so the layouts cannot
--- be rebuilt on a resize and the decision is made once.
local panelled = false

---@return boolean
local function log_running()
  local ok, logcat = pcall(require, "user.integrations.unity.android.logcat")
  return ok and logcat.running()
end

--- Give the panel's panes the heights they were configured with.
---
--- dap-ui asks for them itself and gets them wrong: `WindowLayout:resize` walks
--- its windows with `pairs`, so a vertical stack has its heights set in whatever
--- order the table happens to yield, and each one takes its space from a
--- neighbour that may not have been sized yet. Four panes come out as roughly
--- one, so `stacks` ends up a single row. Setting them bottom upwards is
--- deterministic: each pane takes from the one above, and the top absorbs what
--- rounding leaves over.
local function size_panel()
  local layout = require("dapui.windows").layouts[PANEL]
  if not layout or not layout:is_open() then return end

  local wins = layout.opened_wins
  if #wins ~= #PANEL_ELEMENTS then return end

  local total = 0
  for _, win in ipairs(wins) do
    total = total + vim.api.nvim_win_get_height(win)
  end

  for i = #wins, 2, -1 do
    pcall(vim.api.nvim_win_set_height, wins[i], math.max(1, math.floor(PANEL_ELEMENTS[i].size * total)))
  end
end

--- Put both areas into the shape asked for, from nothing.
---
--- Rebuilt rather than adjusted because `dapui.open` already closes and reopens
--- the layouts below the one it is given, to get the splits in the right order.
--- Doing it here means that order is ours to state: the panel first, so the dock
--- built after it spans the full width instead of stopping at its edge.
---@param next_dock integer|nil
---@param next_panel boolean
local function apply(next_dock, next_panel)
  if dock == next_dock and panel == next_panel then return end
  local dapui = require "dapui"

  if panel then dapui.close { layout = PANEL } end
  if dock then dapui.close { layout = dock } end

  dock, panel = next_dock, next_panel
  if panel then dapui.open { layout = PANEL } end
  if dock then dapui.open { layout = dock } end
  if panel then size_panel() end
end

--- Every transition goes through here, so there is one description of what
--- should be showing rather than one per event.
function M.sync()
  local live = log_running()
  if attached then return apply(live and SESSION_WITH_LOG or SESSION, panelled) end
  apply(live and LOG_ONLY or nil, false)
end

--- Everything off, and stay off. Deliberately stopping means nothing should come
--- back the next time the log has something to say, so the device is let go of
--- too -- `:UnityDeviceLog` starts it again when it is wanted without a debugger.
function M.hide()
  attached = false
  apply(nil, false)
  pcall(function() require("user.integrations.unity.android").unwatch() end)
end

--- The session ended on its own: the adapter said so, or the app took it with
--- it. The panel goes, but a log is exactly what you want to read at that
--- moment, so the dock drops back to it rather than closing.
function M.end_session()
  attached = false
  M.sync()
end

--- A session has begun. The panel opens now rather than at the first breakpoint.
function M.begin_session()
  attached = true
  M.sync()
end

--- `<Leader>du`. Off if anything is showing, otherwise whatever the state calls
--- for -- which with no session and no log is nothing at all.
function M.toggle()
  if dock or panel then return apply(nil, false) end
  M.sync()
end

--- Teach dap-ui to survive a value the adapter never sent.
---
--- It hands an `evaluate` response straight to `format_value`, which splits it
--- with `vim.gsplit` -- and `vim.gsplit` raises on a nil. The DAP spec makes
--- `result` required, but the Unity adapter answers a hover it will not
--- stringify with a body carrying a `variablesReference` and no `result` at all.
--- The render then throws inside an nio task with no error handler, so what
--- lands in the message area is a twenty-line traceback instead of a value, and
--- the float comes up empty. Hover, watches and scopes all render through this
--- one function, so one guard covers all three.
local function harden_values()
  local util = require "dapui.util"
  if util.user_nil_value_guard then return end
  util.user_nil_value_guard = true

  local format_value = util.format_value
  ---@param value string|nil
  function util.format_value(value_start, value) return format_value(value_start, value or "<unavailable>") end
end

--- The log is taught to be a dap-ui element: a buffer someone else fills and a
--- render with nothing to do. `allow_without_session` is what shows it with no
--- debugger at all, which is most of the time it is worth looking at.
local registered = false

local function register_logcat()
  if registered then return end
  registered = true
  -- `register_element` raises rather than replacing when the name is taken,
  -- which a second `setup` would otherwise do.
  pcall(require("dapui").register_element, "logcat", {
    render = function() end,
    buffer = function() return require("user.integrations.unity.android.logcat").buffer() end,
    allow_without_session = true,
  })
end

--- Register both areas and tie them to the session lifecycle.
---@param opts table|nil dapui options from the plugin spec
function M.setup(opts)
  local dap, dapui = require "dap", require "dapui"
  local debug = require "user.debug"

  harden_values()

  panelled = roomy()
  local layouts = M.layouts()

  docked = {}
  local shown = panelled and { SESSION, SESSION_WITH_LOG, PANEL } or { SESSION, SESSION_WITH_LOG }
  for _, index in ipairs(shown) do
    for _, element in ipairs(layouts[index].elements) do
      docked[element.id] = true
    end
  end

  dapui.setup(vim.tbl_deep_extend("force", { layouts = layouts }, opts or {}))
  register_logcat()
  require("user.debug.repl").setup()

  -- On attach and launch rather than on the first `stopped`: the panel being
  -- there is how you know a debugger is.
  dap.listeners.after.attach.user_dapui = function() M.begin_session() end
  dap.listeners.after.launch.user_dapui = function() M.begin_session() end

  dap.listeners.after.attach.user_debug_session = debug.on_session_start
  dap.listeners.after.launch.user_debug_session = debug.on_session_start

  -- Both the events the adapter may send and the requests nvim-dap issues
  -- itself: netcoredbg closes the connection instead of announcing it, and
  -- `dap.close()` announces nothing at all, so a stop is only reliably a stop if
  -- every path is covered. The log is not part of the session and survives it.
  local function finish()
    M.end_session()
    debug.on_session_end()
  end
  dap.listeners.before.event_terminated.user_dapui = finish
  dap.listeners.before.event_exited.user_dapui = finish
  dap.listeners.after.terminate.user_dapui = finish
  dap.listeners.after.disconnect.user_dapui = finish

  vim.api.nvim_create_autocmd("User", {
    pattern = "UnityLogcat",
    group = vim.api.nvim_create_augroup("user_debug_logcat", { clear = true }),
    desc = "Follow the device log in and out of the debug dock",
    callback = function() M.sync() end,
  })
end

return M
