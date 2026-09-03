local M = {}

-- One generation per client/token lets old timers become harmless when a
-- server reports more progress before the timeout elapses.
local generations = {}

---@param data { client_id: integer, params: lsp.ProgressParams }|nil
---@param timeout_ms integer
function M.expire(data, timeout_ms)
  if not data or not data.params then return end

  local id = ("%s.%s"):format(data.client_id, data.params.token)
  local value = data.params.value
  if type(value) == "table" and value.kind == "end" then
    generations[id] = nil
    return
  end

  local generation = (generations[id] or 0) + 1
  generations[id] = generation

  vim.defer_fn(function()
    if generations[id] ~= generation then return end
    generations[id] = nil

    local ok, astrolsp = pcall(require, "astrolsp")
    if not ok or not astrolsp.lsp_progress or not astrolsp.lsp_progress[id] then return end

    astrolsp.lsp_progress[id] = nil
    vim.api.nvim_exec_autocmds("User", { pattern = "AstroLspProgress", modeline = false })
  end, timeout_ms)
end

return M
