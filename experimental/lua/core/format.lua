local M = {}

local enabled = false

---@return boolean
function M.is_enabled() return enabled end

---@param state boolean
function M.set(state) enabled = state end

local function in_diff(bufnr)
  for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.wo[winid].diff then return true end
  end
  return false
end

---@param bufnr integer
function M.on_write(bufnr)
  if not enabled then return end
  local bo = vim.bo[bufnr]
  -- A review holds its buffers readonly; changing one costs the W10 sleep and
  -- reformats a diff side out from under the comparison.
  if bo.buftype ~= "" or bo.readonly or not bo.modifiable or in_diff(bufnr) then return end
  local clients = vim.lsp.get_clients { bufnr = bufnr, method = "textDocument/formatting" }
  if #clients == 0 then return end
  local ok, err = pcall(vim.lsp.buf.format, { bufnr = bufnr, async = false, timeout_ms = 2000 })
  if not ok then vim.notify(tostring(err), vim.log.levels.WARN, { title = "Format on save" }) end
end

return M
