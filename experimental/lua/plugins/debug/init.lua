---@param module string
---@param fn string
---@return fun()
local function call(module, fn)
  return function() require("plugins.debug." .. module)[fn]() end
end

local keys = {
  { "<F5>", call("session", "continue"), desc = "Debug: continue" },
  { "<F10>", call("session", "step_over"), desc = "Debug: step over" },
  { "<F11>", call("session", "step_into"), desc = "Debug: step into" },
  { "<F12>", call("session", "step_out"), desc = "Debug: step out" },

  { "<Leader>dc", call("session", "continue"), desc = "Continue" },
  { "<Leader>dn", call("session", "step_over"), desc = "Step over" },
  { "<Leader>di", call("session", "step_into"), desc = "Step into" },
  { "<Leader>do", call("session", "step_out"), desc = "Step out" },
  { "<Leader>dt", call("session", "run_to_cursor"), desc = "Run to cursor" },
  { "<Leader>dj", call("session", "down"), desc = "Down a frame" },
  { "<Leader>dk", call("session", "up"), desc = "Up a frame" },
  { "<Leader>dq", call("session", "stop"), desc = "Stop the session" },

  { "<Leader>db", call("breakpoints", "toggle"), desc = "Toggle breakpoint" },
  { "<Leader>dB", call("breakpoints", "condition"), desc = "Conditional breakpoint" },
  { "<Leader>dh", call("breakpoints", "hit_condition"), desc = "Breakpoint after N hits" },
  { "<Leader>dl", call("breakpoints", "logpoint"), desc = "Logpoint" },
  { "<Leader>dL", call("breakpoints", "list"), desc = "List breakpoints" },
  { "<Leader>dm", call("breakpoints", "toggle_mute"), desc = "Mute or unmute breakpoints" },
  { "<Leader>dx", call("breakpoints", "clear"), desc = "Delete every breakpoint" },

  { "<Leader>de", call("inspect", "evaluate"), desc = "Evaluate an expression" },
  { "<Leader>de", call("inspect", "eval"), mode = "x", desc = "Evaluate the selection" },
  { "<Leader>dw", call("inspect", "watch"), desc = "Watch an expression" },
  { "<Leader>ds", function() require("plugins.debug.ui").float "stacks" end, desc = "Stack frames" },
  { "<Leader>dv", function() require("plugins.debug.ui").float "scopes" end, desc = "Scopes" },
  { "<Leader>dr", call("ui", "repl"), desc = "Debug REPL" },
  { "<Leader>du", call("ui", "toggle"), desc = "Toggle the debug panel" },
}

local store = require("plugins.debug.breakpoints").store_path(vim.fn.getcwd())

---@type LazySpec
return {
  "mfussenegger/nvim-dap",
  dependencies = {
    { "rcarriga/nvim-dap-ui", dependencies = { "nvim-neotest/nvim-nio" } },
  },
  keys = keys,
  -- A project whose breakpoints were stored wants its signs before the first
  -- debug key is pressed. Everywhere else the debugger stays unloaded.
  event = vim.uv.fs_stat(store) and "VeryLazy" or nil,
  config = function() require("plugins.debug.session").setup() end,
}
