local M = {}

local exception_filters = {}

local function dap() return require "dap" end
local function dapui() return require "dapui" end

-- The panels are meant to mirror the session lifecycle, but nvim-dap only
-- dispatches `event_terminated`/`event_exited` when the *adapter* chooses to
-- send them, and `dap.close()` sends nothing at all. Every stop path therefore
-- closes the UI itself rather than trusting an event that may never arrive.
function M.close_ui() dapui().close() end

function M.toggle_ui() dapui().toggle() end

function M.terminate()
  dap().terminate()
  M.close_ui()
end

function M.close()
  dap().close()
  M.close_ui()
end

function M.restart()
  if not dap().session() then
    return vim.notify("No active debug session to restart", vim.log.levels.INFO, { title = "Debug" })
  end
  dap().restart()
end

function M.conditional_breakpoint()
  vim.ui.input({ prompt = "Breakpoint condition: " }, function(condition)
    if condition and vim.trim(condition) ~= "" then dap().set_breakpoint(condition) end
  end)
end

function M.breakpoints() dap().list_breakpoints(true) end

function M.exceptions()
  vim.ui.input(
    { prompt = "Exception filters (comma-separated; empty clears): ", default = table.concat(exception_filters, ",") },
    function(value)
      exception_filters = {}
      for filter in (value or ""):gmatch "[^,%s]+" do
        table.insert(exception_filters, filter)
      end
      dap().set_exception_breakpoints(exception_filters)
    end
  )
end

return M
