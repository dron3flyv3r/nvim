local M = {}

local NAME = "spell"
local ADD = "spell.add"
local SUGGESTIONS = 5

---@param bufnr integer
---@return integer?
local function window_of(bufnr)
  local current = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(current) == bufnr then return current end
  local win = vim.fn.bufwinid(bufnr)
  return win ~= -1 and win or nil
end

-- `spellbadword()` on the word itself ignores the regions treesitter and syntax
-- limit spelling to, and flags code; `[s` honours them.
---@param win integer
---@param row integer 0-based
---@param col integer 0-based byte
---@return integer? start, string? word
local function misspelled_at(win, row, col)
  return vim.api.nvim_win_call(win, function()
    if not vim.wo.spell then return nil end
    local view, wrapscan = vim.fn.winsaveview(), vim.o.wrapscan
    vim.o.wrapscan = false
    vim.api.nvim_win_set_cursor(win, { row + 1, col + 1 })
    vim.cmd "silent! keepjumps normal! [s"
    local found_row, start = unpack(vim.api.nvim_win_get_cursor(win))
    local word = vim.fn.spellbadword()[1]
    vim.o.wrapscan = wrapscan
    vim.fn.winrestview(view)
    if found_row == row + 1 and start <= col and col < start + #word then return start, word end
  end)
end

---@param params lsp.CodeActionParams
---@return lsp.CodeAction[]
local function code_actions(params)
  local only = params.context and params.context.only
  if only and not vim.list_contains(only, "quickfix") then return {} end
  local uri = params.textDocument.uri
  local win = window_of(vim.uri_to_bufnr(uri))
  if not win then return {} end
  local row, col = params.range.start.line, params.range.start.character
  local start, word = misspelled_at(win, row, col)
  if not (start and word) then return {} end

  local range = { start = { line = row, character = start }, ["end"] = { line = row, character = start + #word } }
  local actions = {}
  for i, suggestion in ipairs(vim.api.nvim_win_call(win, function() return vim.fn.spellsuggest(word, SUGGESTIONS) end)) do
    actions[i] = {
      title = ("Change '%s' to '%s'"):format(word, suggestion),
      kind = "quickfix",
      isPreferred = i == 1,
      edit = { changes = { [uri] = { { range = range, newText = suggestion } } } },
    }
  end
  actions[#actions + 1] = {
    title = ("Add '%s' to the dictionary"):format(word),
    kind = "quickfix",
    command = { title = "Add to the dictionary", command = ADD, arguments = { word } },
  }
  return actions
end

local handlers = {
  initialize = function()
    return {
      capabilities = { codeActionProvider = { codeActionKinds = { "quickfix" } }, positionEncoding = "utf-8" },
      serverInfo = { name = NAME },
    }
  end,
  shutdown = function() return vim.NIL end,
  ["textDocument/codeAction"] = code_actions,
}

---@param dispatchers vim.lsp.rpc.Dispatchers
---@return vim.lsp.rpc.PublicClient
local function server(dispatchers)
  local closing, id = false, 0
  return {
    request = function(method, params, callback)
      id = id + 1
      local handler = handlers[method]
      local err = not handler and vim.lsp.rpc.rpc_response_error(vim.lsp.protocol.ErrorCodes.MethodNotFound) or nil
      local result = handler and handler(params)
      vim.schedule(function() callback(err, result) end)
      return true, id
    end,
    notify = function(method)
      if method == "exit" then dispatchers.on_exit(0, 0) end
      return true
    end,
    is_closing = function() return closing end,
    terminate = function() closing = true end,
  }
end

---@param command lsp.Command
---@param ctx { bufnr: integer }
local function add_word(command, ctx)
  local word = command.arguments and command.arguments[1]
  if type(word) ~= "string" then return end
  vim.fn.mkdir(vim.fs.dirname(vim.o.spellfile), "p")
  vim.api.nvim_buf_call(ctx.bufnr, function() vim.cmd.spellgood(word) end)
end

---@type vim.lsp.ClientConfig
local config = { name = NAME, cmd = server, commands = { [ADD] = add_word } }

---@param bufnr integer
function M.attach(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if vim.bo[bufnr].buftype ~= "" or name == "" or name:find("://", 1, true) then return end
  if vim.api.nvim_get_current_buf() == bufnr then vim.wo[0][0].spell = true end
  vim.lsp.start(config, { bufnr = bufnr, silent = true })
end

function M.setup() require("core.statusline").hide_client(NAME) end

return M
