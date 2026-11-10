local M = {}

function M.check()
  local health = vim.health
  health.start "collaboration"

  local path = vim.fn.exepath "teamtype"
  if path == "" then
    health.warn "teamtype is not on PATH, so <Leader>r offers no sharing"
  else
    local version = vim.trim(vim.fn.system { path, "--version" })
    health.ok(("%s: %s"):format(version, path))
    local others = vim.tbl_filter(function(p) return p ~= path end, vim.fn.split(vim.fn.system { "which", "-a", "teamtype" }))
    if #others > 0 then health.info("also on PATH, shadowed: " .. table.concat(others, ", ")) end
  end

  local plugin = require("lazy.core.config").plugins["teamtype-nvim"]
  if plugin and vim.uv.fs_stat(plugin.dir) then
    health.ok "teamtype-nvim is installed; it loads when a file under a running .teamtype/socket is read"
  else
    health.error "teamtype-nvim is not installed"
  end
end

return M
