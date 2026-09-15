-- Adapters that nothing else registers.
--
-- `cmake-tools` hands nvim-dap a configuration of type `codelldb` and assumes
-- the adapter behind that name exists; it never did, so launching a CMake target
-- under the debugger failed with an unknown-adapter error. Rust reaches the same
-- adapter through rustaceanvim, which finds Mason's copy on its own -- this is
-- for everything that does not.
--
-- The Unity adapter is registered separately, by
-- `user.integrations.unity.dap`, because it has to be located inside a VS Code
-- extension directory first.
local M = {}

---@return string|nil
local function codelldb()
  local found = vim.fn.exepath "codelldb"
  if found ~= "" then return found end

  -- Mason's `bin` is only on `$PATH` once Mason has loaded, which is not
  -- guaranteed to have happened by the time nvim-dap starts.
  local mason = vim.fn.expand "~/.local/share/nvim/mason/bin/codelldb"
  if vim.fn.executable(mason) == 1 then return mason end
end

--- Idempotent.
function M.setup()
  local command = codelldb()
  if not command then return end

  local dap = require "dap"
  dap.adapters.codelldb = {
    type = "server",
    port = "${port}",
    executable = { command = command, args = { "--port", "${port}" } },
  }
end

return M
