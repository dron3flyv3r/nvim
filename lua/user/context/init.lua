-- Project-aware actions without replacing Neovim's editing language.
-- Providers describe what is meaningful for the current buffer; this module
-- merges them, selects the strongest implementation of a universal verb, and
-- exposes the complete set through a transient vim.ui.select picker.
local M = {}

---@class user.Context
---@field bufnr integer
---@field file string
---@field filetype string
---@field cwd string
---@field providers user.ContextProvider[]

---@class user.ContextAction
---@field id string
---@field label string
---@field category? string
---@field verb? "run"|"test"|"debug"|"build"|"output"|"stop"
---@field priority? integer
---@field available? boolean|string|fun(ctx: user.Context): boolean|string
---@field run fun(ctx: user.Context)
---@field repeat_action? fun(ctx: user.Context)
---@field provider? user.ContextProvider

---@class user.ContextProvider
---@field id string
---@field name string
---@field priority? integer
---@field detect fun(ctx: user.Context): boolean|string
---@field actions fun(ctx: user.Context): user.ContextAction[]
---@field status? fun(ctx: user.Context): string[]

local providers = {}
local last ---@type { action: user.ContextAction, provider_id: string }?

---@param provider user.ContextProvider
function M.register(provider)
  assert(type(provider.id) == "string" and provider.id ~= "", "context provider needs an id")
  assert(type(provider.detect) == "function", "context provider needs detect()")
  assert(type(provider.actions) == "function", "context provider needs actions()")
  providers[provider.id] = provider
end

local function base_context(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return {
    bufnr = bufnr,
    file = vim.api.nvim_buf_get_name(bufnr),
    filetype = vim.bo[bufnr].filetype,
    cwd = vim.fn.getcwd(),
    providers = {},
  }
end

---@param value boolean|string|fun(ctx: user.Context): boolean|string|nil
---@param ctx user.Context
---@return boolean, string?
local function availability(value, ctx)
  if type(value) == "function" then
    local ok, result = pcall(value, ctx)
    if not ok then return false, tostring(result) end
    value = result
  end
  if value == nil or value == true then return true end
  if value == false then return false, "not available in this context" end
  return false, value
end

---@param bufnr? integer
---@return user.Context
function M.resolve(bufnr)
  local ctx = base_context(bufnr)
  for _, provider in pairs(providers) do
    local ok, detected = pcall(provider.detect, ctx)
    if ok and detected then
      provider._detail = type(detected) == "string" and detected or nil
      table.insert(ctx.providers, provider)
    end
  end
  table.sort(ctx.providers, function(a, b)
    local ap, bp = a.priority or 0, b.priority or 0
    return ap == bp and a.name < b.name or ap > bp
  end)
  return ctx
end

---@param ctx? user.Context
---@return user.ContextAction[]
function M.actions(ctx)
  ctx = ctx or M.resolve()
  local actions = {}
  for _, provider in ipairs(ctx.providers) do
    local ok, supplied = pcall(provider.actions, ctx)
    if ok then
      for _, action in ipairs(supplied or {}) do
        action.provider = provider
        action.category = action.category or "Actions"
        action.priority = action.priority or provider.priority or 0
        table.insert(actions, action)
      end
    end
  end
  table.sort(actions, function(a, b)
    if a.category ~= b.category then return a.category < b.category end
    if a.priority ~= b.priority then return a.priority > b.priority end
    return a.label < b.label
  end)
  return actions
end

---@param action user.ContextAction
---@param ctx? user.Context
function M.execute(action, ctx)
  ctx = ctx or M.resolve()
  local ok, reason = availability(action.available, ctx)
  if not ok then
    vim.notify(reason or "Action unavailable", vim.log.levels.WARN, { title = action.label })
    return
  end
  local ran, err = pcall(action.run, ctx)
  if not ran then
    vim.notify(err, vim.log.levels.ERROR, { title = action.label })
    return
  end
  if action.repeat_action then last = { action = action, provider_id = action.provider and action.provider.id or "" } end
end

---@param verb user.ContextAction.verb
---@param ctx? user.Context
---@return user.ContextAction?
function M.action_for_verb(verb, ctx)
  ctx = ctx or M.resolve()
  local candidates = vim.tbl_filter(function(action) return action.verb == verb end, M.actions(ctx))
  table.sort(candidates, function(a, b)
    if a.priority ~= b.priority then return a.priority > b.priority end
    return a.label < b.label
  end)
  for _, action in ipairs(candidates) do
    local available = availability(action.available, ctx)
    if available then return action end
  end
end

---@param verb user.ContextAction.verb
function M.run_verb(verb)
  local ctx = M.resolve()
  local action = M.action_for_verb(verb, ctx)
  if action then return M.execute(action, ctx) end
  vim.notify(
    ("No %s action for %s -- <Leader>ra shows what is available"):format(verb, ctx.filetype ~= "" and ctx.filetype or "this buffer"),
    vim.log.levels.INFO,
    { title = "Context" }
  )
end

function M.repeat_last()
  if not last then
    vim.notify("No repeatable contextual action has run yet", vim.log.levels.INFO, { title = "Context" })
    return
  end
  local ctx = M.resolve()
  if last.provider_id ~= "" and not vim.iter(ctx.providers):any(function(provider) return provider.id == last.provider_id end) then
    vim.notify("The last action belongs to a different context", vim.log.levels.INFO, { title = "Context" })
    return
  end
  local ok, err = pcall(last.action.repeat_action, ctx)
  if not ok then vim.notify(err, vim.log.levels.ERROR, { title = "Repeat " .. last.action.label }) end
end

function M.pick()
  local ctx = M.resolve()
  local actions = M.actions(ctx)
  if vim.tbl_isempty(actions) then
    vim.notify("No contextual actions for this buffer", vim.log.levels.INFO, { title = "Context" })
    return
  end
  local names = vim.tbl_map(function(provider) return provider.name end, ctx.providers)
  vim.ui.select(actions, {
    prompt = "Context: " .. table.concat(names, " + "),
    format_item = function(action)
      local ok, reason = availability(action.available, ctx)
      local prefix = ("%-12s"):format(action.category)
      return prefix .. action.label .. (ok and "" or "  [" .. (reason or "unavailable") .. "]")
    end,
  }, function(action)
    if action then M.execute(action, ctx) end
  end)
end

function M.status()
  local ctx = M.resolve()
  local lines = {
    "buffer: " .. (ctx.file ~= "" and vim.fn.fnamemodify(ctx.file, ":~") or "[unnamed]"),
    "filetype: " .. (ctx.filetype ~= "" and ctx.filetype or "[none]"),
    "providers: " .. (#ctx.providers > 0 and table.concat(vim.tbl_map(function(p) return p.name end, ctx.providers), ", ") or "none"),
  }
  for _, provider in ipairs(ctx.providers) do
    if provider._detail then table.insert(lines, ("  %s: %s"):format(provider.name, provider._detail)) end
    if provider.status then vim.list_extend(lines, provider.status(ctx) or {}) end
  end
  for _, action in ipairs(M.actions(ctx)) do
    local ok, reason = availability(action.available, ctx)
    if not ok then table.insert(lines, ("  unavailable %s: %s"):format(action.label, reason or "unknown reason")) end
  end
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "Context status" })
end

function M.setup()
  for _, name in ipairs { "tasks", "python", "notebook", "rust", "cpp", "cmake", "unity" } do
    M.register(require("user.context.providers." .. name))
  end
end

return M
