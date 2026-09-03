local M = {}

---@param bufnr integer
---@param lnum integer 0-indexed line
---@param col integer 0-indexed byte column
---@return lsp.Diagnostic[]
local function diagnostics_at(bufnr, lnum, col)
  local cursor = vim.pos(bufnr, lnum, col)
  local at = {}
  for _, d in ipairs(vim.diagnostic.get(bufnr, { lnum = lnum })) do
    -- Non-LSP diagnostics (none-ls's own, for instance) carry no `user_data.lsp`
    -- and have nothing to send.
    local lsp_diagnostic = d.user_data and d.user_data.lsp
    if lsp_diagnostic then
      local start = vim.pos(bufnr, d.lnum, d.col)
      local finish = vim.pos(bufnr, d.end_lnum or d.lnum, d.end_col or d.col)
      local hit = (start == finish) and cursor == start or (start <= cursor and cursor < finish)
      if hit then table.insert(at, lsp_diagnostic) end
    end
  end
  return at
end

---@param bufnr integer
---@param win integer
---@param callback fun(found: boolean)
local function probe_cursor(bufnr, win, callback)
  local cursor = vim.api.nvim_win_get_cursor(win)
  local context = {
    diagnostics = diagnostics_at(bufnr, cursor[1] - 1, cursor[2]),
    triggerKind = vim.lsp.protocol.CodeActionTriggerKind.Invoked,
  }

  vim.lsp.buf_request_all(bufnr, "textDocument/codeAction", function(client)
    local params = vim.lsp.util.make_range_params(win, client.offset_encoding)
    params.context = context
    return params
  end, function(results)
    for _, result in pairs(results) do
      if result.result and next(result.result) then return callback(true) end
    end
    callback(false)
  end)
end

--- Run `present` for the code actions at the cursor, falling back to the whole
--- line when the cursor alone turns up nothing.
---@param present fun(opts: table) `vim.lsp.buf.code_action`, or a drop-in for it
---@return function
function M.code_action(present)
  return function()
    local bufnr, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()

    -- Visual mode, or no server to ask: hand straight over. `present` does its
    -- own "not supported" / "no actions" reporting, so the empty case still
    -- says something.
    local mode = vim.api.nvim_get_mode().mode
    local clients = vim.lsp.get_clients { bufnr = bufnr, method = "textDocument/codeAction" }
    if mode == "v" or mode == "V" or not next(clients) then return present {} end

    probe_cursor(bufnr, win, function(found)
      if found then return present {} end

      local lnum = vim.api.nvim_win_get_cursor(win)[1]
      local text = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
      -- `{row, col}` mark-indexed, i.e. 1-indexed row and a *byte* column;
      -- `make_given_range_params` converts to the client's encoding for us.
      present { range = { start = { lnum, 0 }, ["end"] = { lnum, #text } } }
    end)
  end
end

return M
