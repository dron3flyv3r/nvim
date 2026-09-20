local M = {}

local SIGNS = {
  DapBreakpoint = { text = "●", texthl = "DiagnosticSignError" },
  DapBreakpointCondition = { text = "◆", texthl = "DiagnosticSignWarn" },
  DapBreakpointRejected = { text = "○", texthl = "DiagnosticSignHint" },
  DapLogPoint = { text = "▸", texthl = "DiagnosticSignInfo" },
  DapStopped = { text = "▶", texthl = "DiagnosticSignOk", linehl = "DapStoppedLine" },
}

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "Debug", id = "plugins_debug_session" })
end

local function breakpoints() return require "plugins.debug.breakpoints" end
local function ui() return require "plugins.debug.ui" end

local live = false
local running = "debug session"
local exit_code = nil
local tracing = false
local ran_before = false

local REASONS = {
  exited = "the program exited",
  terminated = "the adapter ended it",
  stopped = "stopped from Neovim",
  detached = "detached",
}

---@param session? table
---@return string
local function describe(session)
  local config = session and session.config or {}
  return config.name or "debug session"
end

---@param session? table
local function on_start(session)
  if live then return end
  live = true
  ran_before = true
  running = describe(session)
  exit_code = nil
  ui().open()
  require("plugins.debug.inspect").on_session_start()
  notify(running)
end

-- Both the events an adapter may send and the requests nvim-dap issues itself: an
-- adapter that closes the connection instead of announcing it, and a local
-- disconnect, announce nothing between them, so a stop is only reliably a stop if
-- every path is covered. The REPL is left alone -- its output is worth reading
-- once the session is gone.
---@param reason string
---@return fun()
local function ending(reason)
  return function()
    if not live then return end
    live = false
    ui().close()
    require("plugins.debug.inspect").on_session_end()
    -- A session that ends with no reason reads as a crash. It usually is not
    -- one: stepping past the end of main exits the program like any other run.
    local detail = exit_code and ("the program exited with %d"):format(exit_code) or REASONS[reason]
    notify(("%s -- %s"):format(running, detail))
  end
end

---@param fn fun()
---@return fun()
local function needs_session(fn)
  return function()
    if not require("dap").session() then
      return notify("No debug session -- start one from <Leader>r", vim.log.levels.WARN)
    end
    fn()
  end
end

M.step_over = needs_session(function() require("dap").step_over() end)
M.step_into = needs_session(function() require("dap").step_into() end)
M.step_out = needs_session(function() require("dap").step_out() end)
M.step_back = needs_session(function() require("dap").step_back() end)
M.run_to_cursor = needs_session(function() require("dap").run_to_cursor() end)
M.up = needs_session(function() require("dap").up() end)
M.down = needs_session(function() require("dap").down() end)

--- With no session this is the Debug menu rather than a guess: starting one is
--- the language's business, and `<Leader>r` is where a language is asked.
function M.continue()
  if require("dap").session() then return require("dap").continue() end
  require("core.actions").pick { category = "Debug" }
end

--- The one way out, and the one that takes the panel with it.
---
--- `dap.terminate` is asynchronous -- it sends a request and only closes the
--- session once the adapter answers or a timeout passes -- so the panel is taken
--- down from the callback rather than on the next line.
function M.stop()
  local dap = require "dap"
  local session = dap.session()
  if not session then return ending "stopped"() end

  -- Detaching is not killing. An attach session sits beside a process someone
  -- else started, and nvim-dap's disconnect fallback would otherwise ask for it
  -- to be terminated along with the session.
  local attached = (session.config or {}).request == "attach"
  dap.terminate {
    disconnect_args = { terminateDebuggee = not attached },
    on_done = vim.schedule_wrap(ending(attached and "detached" or "stopped")),
  }
end

---@return string
local function log_path() return require("dap.log").create_logger("dap.log"):get_path() end

--- At the default INFO level the log holds the adapter's lifecycle and nothing
--- else, so an empty one is not evidence that nothing went wrong. Tracing is
--- runtime-only, which is why this drops the old log: what you capture next is
--- exactly the run you are about to make.
local function toggle_trace()
  tracing = not tracing
  if tracing then require("dap.log").create_logger("dap.log"):remove() end
  require("dap").set_log_level(tracing and "TRACE" or "INFO")
  notify(
    tracing and ("Tracing the adapter protocol to %s -- reproduce it now"):format(vim.fn.fnamemodify(log_path(), ":~"))
      or "Adapter tracing off"
  )
end

local function show_log()
  local bufnr = vim.fn.bufadd(log_path())
  vim.fn.bufload(bufnr)
  pcall(vim.cmd.checktime, bufnr)
  require("core.pane").show({ name = "dap log", bufnr = bufnr }, { enter = true })
end

---@type core.ActionProvider
local provider = {
  id = "debug",
  name = "Debugger",
  priority = 20,

  detect = function()
    local session = require("dap").session()
    if session then
      return ("%s -- %s"):format(describe(session), session.stopped_thread_id and "stopped" or "running")
    end
    local count = breakpoints().count()
    if count == 0 then return "no session, no breakpoints" end
    local muted = breakpoints().is_muted() and " (muted)" or ""
    return ("no session, %d breakpoint%s%s"):format(count, count == 1 and "" or "s", muted)
  end,

  actions = function()
    local adapters = require "plugins.debug.adapters"
    local function session_live() return require("dap").session() ~= nil or "No debug session" end

    return {
      {
        id = "continue",
        label = "Continue",
        category = "Debug",
        available = session_live,
        run = function() require("dap").continue() end,
      },
      {
        id = "stop",
        label = "Stop the debug session",
        category = "Debug",
        available = session_live,
        run = M.stop,
      },
      {
        id = "attach_process",
        label = "Attach to a running process",
        category = "Debug",
        available = function() return adapters.codelldb() ~= nil or adapters.install_hint() end,
        run = function()
          require("dap").run {
            type = "codelldb",
            request = "attach",
            name = "Attach to process",
            pid = require("dap.utils").pick_process,
            cwd = vim.fn.getcwd(),
          }
        end,
      },
      {
        id = "run_last",
        label = "Run the last debug configuration again",
        category = "Debug",
        available = ran_before or "Nothing has been debugged yet",
        run = function() require("dap").run_last() end,
      },
      {
        id = "program",
        label = "Show the program's output",
        category = "Inspect",
        repeatable = false,
        run = function()
          if not ui().program() then
            notify("This session has no terminal of its own -- its output is in the REPL", vim.log.levels.WARN)
          end
        end,
      },
      {
        id = "repl",
        label = "Show the debug REPL",
        category = "Inspect",
        repeatable = false,
        run = function() ui().repl() end,
      },
      {
        id = "breakpoints",
        label = "List every breakpoint",
        category = "Inspect",
        repeatable = false,
        run = function() breakpoints().list() end,
      },
      {
        id = "log",
        label = "Show the adapter log",
        category = "Inspect",
        repeatable = false,
        run = show_log,
      },
      {
        id = "trace",
        label = tracing and "Stop tracing the adapter protocol" or "Trace the adapter protocol",
        category = "Maintenance",
        repeatable = false,
        run = toggle_trace,
      },
      {
        id = "mute",
        label = breakpoints().is_muted() and "Let the breakpoints fire again" or "Mute every breakpoint",
        category = "Maintenance",
        run = function() breakpoints().toggle_mute() end,
      },
      {
        id = "clear",
        label = "Delete every breakpoint",
        category = "Maintenance",
        run = function() breakpoints().clear() end,
      },
      {
        id = "forget",
        label = "Forget the breakpoints stored for this project",
        category = "Maintenance",
        repeatable = false,
        run = function() breakpoints().forget() end,
      },
    }
  end,

  status = function()
    local store = breakpoints().store_path(vim.fn.getcwd())
    return {
      ("  adapters: %s"):format(table.concat(require("plugins.debug.adapters").names(), ", ")),
      ("  breakpoints: %d%s"):format(breakpoints().count(), breakpoints().is_muted() and " (muted)" or ""),
      ("  store: %s"):format(vim.uv.fs_stat(store) and vim.fn.fnamemodify(store, ":~") or "none yet"),
      ("  log: %s (%s)"):format(vim.fn.fnamemodify(log_path(), ":~"), tracing and "tracing" or "INFO, lifecycle only"),
    }
  end,
}

local function define_signs()
  vim.api.nvim_set_hl(0, "DapStoppedLine", { link = "Visual", default = true })
  for name, sign in pairs(SIGNS) do
    vim.fn.sign_define(name, sign)
  end
end

function M.setup()
  define_signs()
  require("plugins.debug.adapters").setup()
  ui().setup()
  breakpoints().setup()

  local dap = require "dap"
  dap.listeners.after.attach.core_debug = on_start
  dap.listeners.after.launch.core_debug = on_start
  dap.listeners.before.event_exited.core_debug = function(_, _, body)
    exit_code = body and body.exitCode
    ending "exited"()
  end
  dap.listeners.before.event_terminated.core_debug = ending "terminated"
  dap.listeners.after.terminate.core_debug = ending "stopped"
  dap.listeners.after.disconnect.core_debug = ending "detached"

  require("core.actions").register(provider)
end

return M
