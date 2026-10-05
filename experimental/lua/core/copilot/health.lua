local M = {}

function M.check()
  local health = vim.health
  local copilot = require "core.copilot"
  health.start "copilot"

  if not copilot.active() then
    health.info "not enabled on this device -- lua/user opts in with require('core.copilot').enable()"
    return
  end

  local binary = vim.fn.exepath(copilot.BINARY)
  if binary == "" then
    health.error(copilot.BINARY .. " is not on PATH", ":MasonInstall " .. copilot.BINARY)
  else
    health.ok(copilot.BINARY .. ": " .. binary)
  end

  local node = copilot.node or vim.fn.exepath "node"
  local result = node ~= "" and vim.system({ node, "--version" }):wait(2000)
  local major, minor = (result and result.stdout or ""):match "^v(%d+)%.(%d+)"
  if not major then
    health.error("no Node.js found", "the server needs Node.js 22.13 or newer")
  elseif tonumber(major) > 22 or (tonumber(major) == 22 and tonumber(minor) >= 13) then
    health.ok(("Node.js %s.%s: %s"):format(major, minor, node))
  else
    health.error(
      ("Node.js %s.%s is too old: %s"):format(major, minor, node),
      "pass a newer one from lua/user with enable { node = ... }"
    )
  end

  local client = copilot.client()
  if client then
    health.ok "the server is running"
  else
    health.info "the server is not running yet -- it starts with the first file buffer"
  end
  health.info("suggestions are " .. (copilot.is_enabled() and "on" or "off"))
end

return M
