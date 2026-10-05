local M = {}

M.HINT = "No js-debug-adapter. Run :MasonInstall js-debug-adapter, then restart."

local BROWSERS = { "google-chrome-stable", "google-chrome", "chromium", "chromium-browser", "brave", "microsoft-edge" }

---@return string|nil
function M.executable()
  local exe = vim.fn.exepath "js-debug-adapter"
  return exe ~= "" and exe or nil
end

---@param callback fun(adapter: table)
function M.resolve(callback)
  local exe = M.executable()
  if not exe then return vim.notify(M.HINT, vim.log.levels.ERROR, { title = "TypeScript" }) end
  -- The adapter binds `localhost`, which can resolve to ::1 while nvim-dap
  -- connects to 127.0.0.1; naming the host keeps both on the same address.
  callback {
    type = "server",
    host = "127.0.0.1",
    port = "${port}",
    executable = { command = exe, args = { "${port}", "127.0.0.1" } },
  }
end

---@return string|nil
function M.browser()
  for _, name in ipairs(BROWSERS) do
    local path = vim.fn.exepath(name)
    if path ~= "" then return path end
  end
end

---@return boolean|string
function M.ready() return M.executable() ~= nil or M.HINT end

M.SKIP_FILES = { "<node_internals>/**", "**/node_modules/**" }

return M
