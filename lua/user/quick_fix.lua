--- VS Code's Ctrl+`.` -- a code-action key that answers where the cursor is,
--- not only where the *column* is.
---
--- WHY THIS FILE EXISTS. `<Leader>xa` and `<Leader>la` both call
--- `textDocument/codeAction` for a zero-width range at the cursor. Every server
--- is free to decide what that range means, and the two servers in this config
--- decide it very differently:
---
---   * basedpyright and ruff answer for the whole statement the cursor is in,
---     and ruff always offers its source-level actions (organize imports, add a
---     `# noqa`). Python therefore always has *something*, wherever you press.
---
---   * clangd resolves the range to the smallest AST node containing it and
---     offers only the tweaks that fit that node. Measured on a four-line
---     method:
---
---         int scaled(int factor) {     -- column 2 (the indent):  nothing
---         ^--- column 8 (the name):  "Move function body to out-of-line"
---
---     One space to the left of the function name and the same key reports
---     `No code actions available`. That is the whole bug report: it looks
---     broken in C++ because the target is a few columns wide, and VS Code
---     never made you aim.
---
--- THE FIX, and why it is a second request rather than just a wider one: ask at
--- the cursor first, and only if nobody offers anything, ask again for the
--- range covering the whole line. Order matters, because the two requests do
--- not return the same list and the precise one is usually the one you meant --
--- with the cursor on `NULL`, clangd offers "Expand macro 'NULL'"; widen to the
--- line and that disappears in favour of "Extract to function", because now the
--- node under the range is the statement. So the widened list is the fallback,
--- never the default: you lose nothing you had, and you gain a hit anywhere on
--- the line when you previously got silence.
---
--- The cost is one extra round trip on the miss path only. clangd has the file
--- parsed already -- enumerating tweaks is a tree walk, not a rebuild -- so
--- this is not noticeable in practice.
---
--- VISUAL MODE IS LEFT ALONE. A selection is already an explicit range, and it
--- is the range the extract tweaks read (see `plugins/refactor.lua`); widening
--- it to whole lines would silently change what "extract this" means.

local M = {}

--- The LSP diagnostics on `lnum` that actually contain the cursor.
---
--- This mirrors what `vim.lsp.buf.code_action` sends as `context.diagnostics`,
--- and it has to: a server's quickfixes are generated *from* the diagnostics in
--- the context, so a probe that sent more of them than the real request would
--- report actions the real request then fails to produce. Same rule as the
--- built-in -- a zero-width diagnostic matches only at its own position,
--- otherwise the cursor must be inside `[start, end)`.
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

--- Does any attached server offer an action for the exact cursor position?
---
--- Answers with the actions discarded -- this only decides which range the real
--- request should use, and re-requesting is cheaper than reimplementing the
--- `codeAction/resolve` round trip and the command execution that follow a
--- choice.
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
