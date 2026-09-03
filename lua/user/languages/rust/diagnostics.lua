local M = {}

local ALSO_FROM_CARGO = {
  ["syntax-error"] = true,
}

---@param diagnostic lsp.Diagnostic
---@return boolean
function M.duplicates_cargo(diagnostic)
  local code = diagnostic.code
  if type(code) ~= "string" then return false end
  if ALSO_FROM_CARGO[code] then return true end
  return code:match "^E%d+$" ~= nil or code:find("_", 1, true) ~= nil
end

---@param report table|nil
local function filter(report)
  if type(report) ~= "table" then return end
  for _, key in ipairs { "diagnostics", "items" } do
    if type(report[key]) == "table" then
      report[key] = vim.tbl_filter(function(d) return not M.duplicates_cargo(d) end, report[key])
    end
  end
  if type(report.relatedDocuments) == "table" then
    for _, related in pairs(report.relatedDocuments) do
      filter(related)
    end
  end
end

---@param method string
---@param inner lsp.Handler|nil
---@return lsp.Handler
function M.handler(method, inner)
  local default = inner or vim.lsp.handlers[method]
  return function(err, result, ctx, config)
    filter(result)
    return default(err, result, ctx, config)
  end
end

--- Install the filter onto an `lsp.ClientConfig`-shaped `handlers` table,
--- wrapping anything already registered for either method.
---@param handlers table<string, lsp.Handler>|nil
---@return table<string, lsp.Handler>
function M.install(handlers)
  handlers = handlers or {}
  for _, method in ipairs { "textDocument/diagnostic", "textDocument/publishDiagnostics" } do
    handlers[method] = M.handler(method, handlers[method])
  end
  return handlers
end

return M
