local M = {}

local hosts = require "core.remote.hosts"

---@param message string
---@param level? integer
local function notify(message, level) vim.notify(message, level or vim.log.levels.INFO, { title = "Remote" }) end

-- netrw reads one slash after the host as "relative to the remote home" and two
-- as the root, which an already-absolute path supplies itself.
---@param dest string
---@param path string
---@return string
function M.url(dest, path) return ("scp://%s/%s"):format(dest, path) end

---@param host core.remote.Host
---@param path string
function M.edit(host, path)
  local url = M.url(host.dest, path)
  require("core.open").file(url)
  notify("Editing " .. path .. " on " .. host.name .. " -- :w writes it back over scp")
end

---@param host core.remote.Host
function M.open(host)
  require("core.remote.browse").start {
    host = host,
    kind = "file",
    start = host.browsed,
    on_choice = function(path)
      hosts.browsed(host, vim.fs.dirname(path))
      M.edit(host, path)
    end,
  }
end

function M.pick() hosts.pick("Open a file on", M.open) end

return M
