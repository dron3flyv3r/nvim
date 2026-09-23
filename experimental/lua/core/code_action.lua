local workspace_edit = require "core.workspace_edit"

local M = {}

---@class core.code_action.Choice
---@field action lsp.Command|lsp.CodeAction
---@field ctx lsp.HandlerContext

---@class core.code_action.Preview
---@field diff? string
---@field notes string[]

---@type table<table, core.code_action.Preview>
local previews = setmetatable({}, { __mode = "k" })
---@type table<table, true>
local resolving = setmetatable({}, { __mode = "k" })

---@param action lsp.Command|lsp.CodeAction
---@return boolean
local function is_command(action) return type(action.command) == "string" end

---@param action lsp.Command|lsp.CodeAction
---@param client vim.lsp.Client
---@return core.code_action.Preview
local function describe(action, client)
  if action.disabled then return { notes = { "Unavailable: " .. action.disabled.reason } } end

  local diff, notes
  if action.edit then
    diff, notes = workspace_edit.diff(action.edit, client.offset_encoding)
  else
    notes = {}
  end

  local command = is_command(action) and action or action.command
  if command then
    local name = ("`%s`"):format(command.command)
    notes[#notes + 1] = diff and ("Then runs %s on the server"):format(name)
      or ("Runs %s on the server, which makes its own changes; they cannot be previewed"):format(name)
  end
  if not diff and #notes == 0 then notes[1] = "Changes nothing" end
  return { diff = diff, notes = notes }
end

---@param choice core.code_action.Choice
---@param on_ready fun()
---@return core.code_action.Preview?
function M.preview(choice, on_ready)
  local action = choice.action
  if previews[action] then return previews[action] end

  local client = vim.lsp.get_client_by_id(choice.ctx.client_id)
  if not client then return { notes = { "The language server is gone" } } end

  local needs_resolve = not is_command(action)
    and not action.disabled
    and not action.edit
    and client:supports_method("codeAction/resolve", choice.ctx.bufnr)
  if not needs_resolve then
    previews[action] = describe(action, client)
    return previews[action]
  end

  if resolving[action] then return nil end
  resolving[action] = true
  client:request("codeAction/resolve", action, function(err, resolved)
    resolving[action] = nil
    previews[action] = describe(not err and resolved or action, client)
    on_ready()
  end, choice.ctx.bufnr)
  return nil
end

return M
