local M = {}
local matcher = require "user.inlay_hints.matcher"
local store = require "user.inlay_hints.store"
local syntax = require "user.inlay_hints.syntax"
local installed = false

---@param result lsp.InlayHint[]
---@param ctx lsp.HandlerContext
---@return lsp.InlayHint[]
function M.filter(result, ctx)
  local bufnr = ctx.bufnr
  if not bufnr or not vim.api.nvim_buf_is_loaded(bufnr) then return result end

  local root = store.root(bufnr)
  local rules = matcher.rules(root)
  if rules.empty then return result end
  if #rules.paths > 0 and matcher.path_ignored(rules, matcher.paths(bufnr, root)) then return {} end
  if next(rules.callees) == nil then return result end

  local parser_ok, parser = pcall(vim.treesitter.get_parser, bufnr, nil, { error = false })
  if not parser_ok or not parser then return result end
  local client = vim.lsp.get_client_by_id(ctx.client_id)
  local encoding = client and client.offset_encoding or "utf-16"

  local kept, lines = {}, {}
  for _, hint in ipairs(result) do
    local keep = true
    if syntax.is_parameter_hint(hint) then
      local line = hint.position.line
      if lines[line] == nil then lines[line] = vim.api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1] or "" end
      local ok, col = pcall(vim.str_byteindex, lines[line], encoding, hint.position.character, false)
      if ok then
        local full, last = syntax.call_at(bufnr, line, col)
        if full and (rules.callees[full] or (last and rules.callees[last])) then keep = false end
      end
    end
    if keep then kept[#kept + 1] = hint end
  end
  return kept
end

function M.refresh()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.lsp.inlay_hint.is_enabled { bufnr = bufnr } then
      vim.lsp.inlay_hint.enable(false, { bufnr = bufnr })
      vim.lsp.inlay_hint.enable(true, { bufnr = bufnr })
    end
  end
end

function M.setup()
  if installed then return end
  installed = true
  local original = vim.lsp.handlers["textDocument/inlayHint"]
  vim.lsp.handlers["textDocument/inlayHint"] = function(err, result, ctx, config)
    if not err and type(result) == "table" and #result > 0 then
      local ok, filtered = pcall(M.filter, result, ctx)
      if ok then result = filtered end
    end
    return original(err, result, ctx, config)
  end
end

return M
