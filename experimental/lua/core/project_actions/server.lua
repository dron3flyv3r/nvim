local json = require "core.project_actions.json"
local schema = require "core.project_actions.schema"

local M = {}

local NAME = "project-actions"
local HIDE = "project_actions.hide"
local SEVERITY = { error = 1, warning = 2, information = 3, hint = 4 }
local KIND = { property = 10, value = 12, enum = 20 }

---@type table<string, string>
local documents = {}
---@type table<string, { hidden: boolean, trust: string }>
local facts = {}
---@type vim.lsp.rpc.Dispatchers?
local dispatchers

---@param starts integer[]
---@param s integer
---@param e integer
---@return lsp.Range
local function range(starts, s, e) return { start = json.position(starts, s), ["end"] = json.position(starts, e) } end

---@param uri string
---@return lsp.Diagnostic[]
local function diagnose(uri)
  local text = documents[uri]
  local starts = json.lines(text)
  local path = vim.uri_to_fname(uri)
  local first_line = range(starts, 1, (text:find("\n", 1, true) or #text + 1))
  local diagnostics = {}
  local known = facts[uri]
  if known and not known.hidden then
    diagnostics[#diagnostics + 1] = {
      range = first_line,
      severity = SEVERITY.warning,
      code = "not-hidden",
      message = "Not hidden from git, so it can be committed. gra hides it in .git/info/exclude.",
    }
  end
  if known and known.trust ~= "trusted" then
    diagnostics[#diagnostics + 1] = {
      range = first_line,
      severity = SEVERITY.information,
      message = "Not trusted, so <Leader>r will not run it. Writing it here trusts it, or run :trust.",
    }
  end
  local _, problems = schema.check(text, schema.root(path))
  for _, problem in ipairs(problems) do
    diagnostics[#diagnostics + 1] = {
      range = range(starts, problem.s, problem.e),
      severity = SEVERITY[problem.severity],
      message = problem.message,
    }
  end
  for _, diagnostic in ipairs(diagnostics) do
    diagnostic.source = NAME
  end
  return diagnostics
end

---@param uri string
local function publish(uri)
  if not (dispatchers and documents[uri]) then return end
  dispatchers.notification("textDocument/publishDiagnostics", { uri = uri, diagnostics = diagnose(uri) })
end

---@param uri string
function M.refresh(uri)
  if not documents[uri] then return end
  local project_actions = require "core.project_actions"
  local path = vim.uri_to_fname(uri)
  facts[uri] = { hidden = project_actions.hidden(path), trust = project_actions.trust_state(path) }
  publish(uri)
end

---@class core.project_actions.Cursor
---@field container? "top"|"action"
---@field slot? "key"|"value"
---@field key? string the key whose value is at the cursor
---@field present table<string, true> keys already set in the object, before the cursor
---@field start integer where the token at the cursor begins
---@field quoted boolean

---@param text string
---@param offset integer
---@return core.project_actions.Cursor
local function cursor_at(text, offset)
  local word = text:sub(1, offset - 1):match "[%w_]*$"
  local stack, last_string, last_key, after = {}, nil, nil, nil
  local in_string, escaped, string_start = false, false, 0
  for i = 1, offset - 1 - #word do
    local c = text:sub(i, i)
    if in_string then
      if escaped then
        escaped = false
      elseif c == "\\" then
        escaped = true
      elseif c == '"' then
        in_string, last_string, after = false, text:sub(string_start + 1, i - 1), '"'
      end
    elseif c == '"' then
      in_string, string_start = true, i
    elseif c == "{" or c == "[" then
      stack[#stack + 1] = { ch = c, key = last_key, present = {} }
      after = c
    elseif c == "}" or c == "]" then
      stack[#stack] = nil
      after = c
    elseif c == ":" then
      last_key, after = last_string, c
      if stack[#stack] and last_string then stack[#stack].present[last_string] = true end
    elseif not c:match "%s" then
      after = c
    end
  end

  local container
  if #stack == 1 and stack[1].ch == "{" then
    container = "top"
  elseif #stack == 3 and stack[2].ch == "[" and stack[2].key == "actions" and stack[3].ch == "{" then
    container = "action"
  end
  local slot = (after == "{" or after == ",") and "key" or after == ":" and "value" or nil
  return {
    container = container,
    slot = slot,
    key = slot == "value" and last_key or nil,
    present = stack[#stack] and stack[#stack].present or {},
    start = in_string and string_start or offset - #word,
    quoted = in_string,
  }
end

---@param at core.project_actions.Cursor
---@return core.project_actions.Field[]?
local function fields_for(at)
  if at.slot ~= "key" then return nil end
  if at.container == "top" then return schema.TOP end
  if at.container == "action" then return schema.ACTION end
end

---@param field core.project_actions.Field
---@return string
local function field_doc(field)
  return ("**%s**, %s%s\n\n%s"):format(
    field.name,
    schema.describe(field.kind),
    field.required and ", required" or "",
    field.doc
  )
end

---@param params lsp.CompletionParams
---@return lsp.CompletionList
local function completion(params)
  local items = {}
  local text = documents[params.textDocument.uri]
  if not text then return { isIncomplete = false, items = items } end
  local starts = json.lines(text)
  local offset = json.offset(starts, params.position)
  local at = cursor_at(text, offset)
  local stop = (at.quoted and text:sub(offset, offset) == '"') and offset + 1 or offset
  local edit = range(starts, at.start, stop)

  local fields = fields_for(at)
  if fields then
    for i, field in ipairs(fields) do
      if not at.present[field.name] then
        items[#items + 1] = {
          label = field.name,
          kind = KIND.property,
          detail = schema.describe(field.kind) .. (field.required and ", required" or ""),
          documentation = { kind = "markdown", value = field.doc },
          sortText = ("%d%02d"):format(field.required and 0 or 1, i),
          insertTextFormat = 2,
          textEdit = { range = edit, newText = field.snippet },
        }
      end
    end
  elseif at.slot == "value" and at.container == "action" and at.key == "category" then
    for i, category in ipairs(schema.CATEGORIES) do
      items[#items + 1] = {
        label = category,
        kind = KIND.enum,
        sortText = ("%02d"):format(i),
        textEdit = { range = edit, newText = ('"%s"'):format(category) },
      }
    end
  elseif at.slot == "value" and at.container == "action" and at.key == "queue" and not at.quoted then
    for _, literal in ipairs { "false", "true" } do
      items[#items + 1] = { label = literal, kind = KIND.value, textEdit = { range = edit, newText = literal } }
    end
  end
  return { isIncomplete = false, items = items }
end

---@param params lsp.HoverParams
---@return lsp.Hover|nil
local function hover(params)
  local text = documents[params.textDocument.uri]
  if not text then return nil end
  local offset = json.offset(json.lines(text), params.position)
  local at = cursor_at(text, offset)
  local s, e = offset, offset
  while text:sub(s - 1, s - 1):match "[%w_]" do
    s = s - 1
  end
  while text:sub(e, e):match "[%w_]" do
    e = e + 1
  end
  local word = text:sub(s, e - 1)

  local fields = fields_for(at)
  local field = fields and schema.field(fields, word)
  if field then return { contents = { kind = "markdown", value = field_doc(field) } } end
  if at.slot == "value" and at.container == "action" and at.key then
    field = schema.field(schema.ACTION, at.key)
    if field then return { contents = { kind = "markdown", value = field_doc(field) } } end
  end
end

---@param params lsp.CodeActionParams
---@return lsp.CodeAction[]
local function code_actions(params)
  local uri = params.textDocument.uri
  local known = facts[uri]
  if not known or known.hidden then return {} end
  return {
    {
      title = "Hide .nvim/ from git in this clone",
      kind = "quickfix",
      isPreferred = true,
      command = { title = "Hide .nvim/ from git", command = HIDE, arguments = { uri } },
    },
  }
end

local requests = {
  initialize = function()
    return {
      capabilities = {
        positionEncoding = "utf-8",
        textDocumentSync = { openClose = true, change = 1, save = true },
        completionProvider = { triggerCharacters = { '"' } },
        hoverProvider = true,
        codeActionProvider = { codeActionKinds = { "quickfix" } },
      },
      serverInfo = { name = NAME },
    }
  end,
  shutdown = function() return vim.NIL end,
  ["textDocument/completion"] = completion,
  ["textDocument/hover"] = hover,
  ["textDocument/codeAction"] = code_actions,
}

local notifications = {
  ["textDocument/didOpen"] = function(params)
    documents[params.textDocument.uri] = params.textDocument.text
    M.refresh(params.textDocument.uri)
  end,
  ["textDocument/didChange"] = function(params)
    local changes = params.contentChanges
    documents[params.textDocument.uri] = changes[#changes].text
    publish(params.textDocument.uri)
  end,
  ["textDocument/didSave"] = function(params) M.refresh(params.textDocument.uri) end,
  ["textDocument/didClose"] = function(params)
    documents[params.textDocument.uri] = nil
    facts[params.textDocument.uri] = nil
  end,
}

---@param client_dispatchers vim.lsp.rpc.Dispatchers
---@return vim.lsp.rpc.PublicClient
local function server(client_dispatchers)
  dispatchers = client_dispatchers
  local closing, id = false, 0
  return {
    request = function(method, params, callback)
      id = id + 1
      local handler = requests[method]
      local err = not handler and vim.lsp.rpc.rpc_response_error(vim.lsp.protocol.ErrorCodes.MethodNotFound) or nil
      local result = handler and handler(params)
      vim.schedule(function() callback(err, result) end)
      return true, id
    end,
    notify = function(method, params)
      if method == "exit" then
        client_dispatchers.on_exit(0, 0)
      elseif notifications[method] then
        vim.schedule(function() notifications[method](params) end)
      end
      return true
    end,
    is_closing = function() return closing end,
    terminate = function() closing = true end,
  }
end

---@param command lsp.Command
local function hide(command)
  local uri = command.arguments and command.arguments[1]
  if type(uri) ~= "string" then return end
  local ok, message = require("core.project_actions").hide(schema.root(vim.uri_to_fname(uri)))
  vim.notify(message, ok and vim.log.levels.INFO or vim.log.levels.WARN, { title = "Project actions" })
  M.refresh(uri)
end

---@type vim.lsp.ClientConfig
M.config = { name = NAME, cmd = server, commands = { [HIDE] = hide } }

return M
