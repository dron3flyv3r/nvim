local M = {}

---@param bufnr integer
local function run(bufnr)
  for _, client in ipairs(vim.lsp.get_clients { bufnr = bufnr, name = "rust-analyzer" }) do
    client:notify("rust-analyzer/runFlycheck", { textDocument = { uri = vim.uri_from_bufnr(bufnr) } })
  end
end

-- A reload from disk sends no didSave, so rust-analyzer keeps the last check's errors until the next :w.
function M.setup()
  vim.api.nvim_create_autocmd("FileChangedShellPost", {
    group = vim.api.nvim_create_augroup("lang_rust_flycheck", { clear = true }),
    pattern = "*.rs",
    callback = function(args) run(args.buf) end,
  })
end

return M
