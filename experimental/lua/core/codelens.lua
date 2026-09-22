local M = {}

local enabled = true

---@type table<string, true>
local suspensions = {}

-- The global marker (no `bufnr` filter) is also what a client consults as it
-- attaches, so a buffer opened later inherits this without an `LspAttach` hook.
local function apply() vim.lsp.codelens.enable(M.is_enabled()) end

---@return boolean
function M.is_enabled() return enabled and next(suspensions) == nil end

---@param state boolean
function M.set(state)
  enabled = state
  suspensions = {}
  apply()
end

---@param reason string
function M.suspend(reason)
  suspensions[reason] = true
  apply()
end

---@param reason string
function M.resume(reason)
  suspensions[reason] = nil
  apply()
end

function M.setup() apply() end

return M
