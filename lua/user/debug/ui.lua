-- One dock across the bottom of the screen, opened when execution actually
-- stops.
--
-- The stock layout puts four elements in a side panel, which is the wrong shape
-- for the language this is mostly used on: `this._feet.position` inside a
-- `Transform` inside a `PlayerController` runs past the edge of a 40-column
-- panel long before it runs out of interesting members. Across the bottom every
-- column gets the full editor width, and two useful panes beat four cramped
-- ones.
local M = {}

--- Four columns need a wide terminal. On anything narrower `watches` is the one
--- to drop: it is the only element reachable another way, through the menu or
--- by typing the expression into the REPL.
---@return table[]
function M.layout()
  local elements = vim.o.columns >= 170
      and {
        { id = "scopes", size = 0.36 },
        { id = "stacks", size = 0.22 },
        { id = "watches", size = 0.16 },
        { id = "repl", size = 0.26 },
      }
    or {
      { id = "scopes", size = 0.40 },
      { id = "stacks", size = 0.26 },
      { id = "repl", size = 0.34 },
    }

  return { { position = "bottom", size = 16, elements = elements } }
end

--- Which elements the dock ended up with. Anything not in it has to be reached
--- another way, or adding to it looks like nothing happening at all.
local docked = {}

---@param id string
---@return boolean
function M.shows(id) return docked[id] == true end

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

--- Register the dock and tie it to the session lifecycle.
---@param opts table|nil dapui options from the plugin spec
function M.setup(opts)
  local dap, dapui = require "dap", require "dapui"
  local debug = require "user.debug"

  harden_values()

  local layouts = M.layout()
  docked = {}
  for _, layout in ipairs(layouts) do
    for _, element in ipairs(layout.elements) do
      docked[element.id] = true
    end
  end

  dapui.setup(vim.tbl_deep_extend("force", { layouts = layouts }, opts or {}))
  require("user.debug.repl").setup()

  -- Attaching is not the same as stopping. A Unity session is attached for
  -- minutes while you keep writing code, and panels during that window are pure
  -- noise -- so the dock waits for the first `stopped` event instead of opening
  -- on `attach`/`launch` the way the plugin suggests.
  dap.listeners.after.event_stopped.user_dapui = function() dapui.open() end

  -- Closing on `event_continued` would close the dock on every single step,
  -- since a step is a continue followed by a stop. `after.continue` fires only
  -- on a continue *request*, which is the deliberate "I am done looking" one.
  dap.listeners.after.continue.user_dapui = function() dapui.close() end

  dap.listeners.after.attach.user_debug_session = debug.on_session_start
  dap.listeners.after.launch.user_debug_session = debug.on_session_start

  -- Both the events the adapter may send and the requests nvim-dap issues
  -- itself: netcoredbg closes the connection instead of announcing it, and
  -- `dap.close()` announces nothing at all, so a stop is only reliably a stop if
  -- every path is covered.
  local function finish()
    dapui.close()
    debug.on_session_end()
  end
  dap.listeners.before.event_terminated.user_dapui = finish
  dap.listeners.before.event_exited.user_dapui = finish
  dap.listeners.after.terminate.user_dapui = finish
  dap.listeners.after.disconnect.user_dapui = finish
end

return M
