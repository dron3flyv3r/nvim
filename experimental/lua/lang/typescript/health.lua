local M = {}

---@param name string
---@param missing string
local function tool(name, missing)
  local path = vim.fn.exepath(name)
  if path ~= "" then return vim.health.ok(("%s: %s"):format(name, path)) end
  vim.health.warn(("%s is not on PATH"):format(name), { missing })
end

function M.check()
  vim.health.start "JavaScript and TypeScript"
  local node = require("lang.typescript.package").node_version()
  if node then
    vim.health.ok(("node %s"):format(tostring(node)))
  else
    vim.health.error("node is not on PATH", { "Nothing in this module runs without it." })
  end
  tool("vtsls", "No language server. Run :MasonInstall vtsls, then restart.")
  tool("vscode-eslint-language-server", "No ESLint diagnostics. Run :MasonInstall eslint-lsp, then restart.")
  tool("js-debug-adapter", require("lang.typescript.debug").HINT)
  local browser = require("lang.typescript.debug").browser()
  if browser then
    vim.health.ok(("browser for debugging: %s"):format(browser))
  else
    vim.health.warn "no Chrome, Chromium, Brave or Edge: the app cannot be debugged in a browser"
  end
  for _, manager in ipairs { "npm", "pnpm", "yarn", "bun" } do
    if vim.fn.executable(manager) == 1 then vim.health.info(("%s: %s"):format(manager, vim.fn.exepath(manager))) end
  end
end

return M
