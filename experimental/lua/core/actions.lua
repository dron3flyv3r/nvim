local M = {}

---@class core.Context
---@field bufnr integer
---@field file string
---@field filetype string
---@field cwd string
---@field providers core.ActionProvider[]
---@field details table<string, string>

---@class core.ActionProvider
---@field id string
---@field name string
---@field priority? integer
---@field detect fun(ctx: core.Context): boolean|string
---@field actions fun(ctx: core.Context): core.Action[]
---@field status? fun(ctx: core.Context): string[]

---@class core.Action
---@field id string
---@field label string
---@field category? core.ActionCategory
---@field priority? integer
---@field available? boolean|string|fun(ctx: core.Context): boolean|string
---@field repeatable? boolean
---@field run fun(ctx: core.Context, opts: core.ActionRunOpts)
---@field provider? core.ActionProvider

---@class core.ActionRunOpts
---@field repeated boolean true when <Leader>R re-ran it rather than the menu choosing it

---@alias core.ActionCategory "Build"|"Run"|"Test"|"Debug"|"Refactor"|"Inspect"|"Maintenance"

---@type core.ActionCategory[]
M.CATEGORIES = { "Build", "Run", "Test", "Debug", "Refactor", "Inspect", "Maintenance" }

local FALLBACK_CATEGORY = "Inspect"

local category_order = {}
for index, name in ipairs(M.CATEGORIES) do
  category_order[name] = index
end

---@type table<string, core.ActionProvider>
local providers = {}

---@type core.Action|nil
local last_action = nil
local last_bufnr = 0

local warned = {}
local function warn_once(key, message)
  if warned[key] then return end
  warned[key] = true
  vim.notify(message, vim.log.levels.WARN, { title = "Actions" })
end

---@param provider core.ActionProvider
function M.register(provider)
  assert(type(provider.id) == "string" and provider.id ~= "", "action provider needs an id")
  assert(type(provider.name) == "string" and provider.name ~= "", "action provider needs a name")
  assert(type(provider.detect) == "function", "action provider needs detect()")
  assert(type(provider.actions) == "function", "action provider needs actions()")
  providers[provider.id] = provider
end

---@param id string
function M.unregister(id) providers[id] = nil end

---@param value boolean|string|fun(ctx: core.Context): boolean|string|nil
---@param ctx core.Context
---@return boolean available
---@return string? reason
local function availability(value, ctx)
  if type(value) == "function" then
    local ok, result = pcall(value, ctx)
    if not ok then return false, tostring(result) end
    value = result
  end
  if value == nil or value == true then return true end
  if value == false then return false, "not available in this context" end
  return false, tostring(value)
end

M.availability = availability

---@param bufnr? integer
---@return core.Context
function M.resolve(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then bufnr = vim.api.nvim_get_current_buf() end
  local ctx = {
    bufnr = bufnr,
    file = vim.api.nvim_buf_get_name(bufnr),
    filetype = vim.bo[bufnr].filetype,
    cwd = vim.fn.getcwd(),
    providers = {},
    details = {},
  }
  for _, provider in pairs(providers) do
    local ok, detected = pcall(provider.detect, ctx)
    if not ok then
      warn_once("detect:" .. provider.id, ("%s: detect() failed: %s"):format(provider.name, detected))
    elseif detected then
      if type(detected) == "string" then ctx.details[provider.id] = detected end
      table.insert(ctx.providers, provider)
    end
  end
  table.sort(ctx.providers, function(a, b)
    local ap, bp = a.priority or 0, b.priority or 0
    if ap ~= bp then return ap > bp end
    return a.name < b.name
  end)
  return ctx
end

---@param action core.Action
---@return integer
local function category_rank(action)
  local rank = category_order[action.category]
  if rank then return rank end
  warn_once(
    ("category:%s:%s"):format(action.provider and action.provider.id or "?", action.id),
    ("%s uses category %q, which is not in the fixed vocabulary. Filed under %s.")
      :format(action.label, tostring(action.category), FALLBACK_CATEGORY)
  )
  return category_order[FALLBACK_CATEGORY]
end

---@param ctx? core.Context
---@return core.Action[]
function M.actions(ctx)
  ctx = ctx or M.resolve()
  local actions = {}
  for _, provider in ipairs(ctx.providers) do
    local ok, supplied = pcall(provider.actions, ctx)
    if not ok then
      warn_once("actions:" .. provider.id, ("%s: actions() failed: %s"):format(provider.name, supplied))
    else
      for _, action in ipairs(supplied or {}) do
        action.provider = provider
        action.priority = action.priority or provider.priority or 0
        action._rank = category_rank(action)
        table.insert(actions, action)
      end
    end
  end
  table.sort(actions, function(a, b)
    if a._rank ~= b._rank then return a._rank < b._rank end
    if a.priority ~= b.priority then return a.priority > b.priority end
    return a.label < b.label
  end)
  return actions
end

---@param action core.Action
---@param ctx? core.Context
---@param opts? core.ActionRunOpts
function M.execute(action, ctx, opts)
  ctx = ctx or M.resolve()
  local ok, reason = availability(action.available, ctx)
  if not ok then
    vim.notify(reason or "Action unavailable", vim.log.levels.WARN, { title = action.label })
    return
  end
  local ran, err = pcall(action.run, ctx, { repeated = opts ~= nil and opts.repeated == true })
  if not ran then
    vim.notify(tostring(err), vim.log.levels.ERROR, { title = action.label })
    return
  end
  if action.repeatable ~= false then
    last_action, last_bufnr = action, ctx.bufnr
  end
end

---@return core.Action|nil
function M.last_run() return last_action end

function M.repeat_last()
  if not last_action then
    vim.notify("No action has been run yet", vim.log.levels.INFO, { title = "Actions" })
    return
  end
  M.execute(last_action, M.resolve(last_bufnr), { repeated = true })
end

---@param action core.Action
---@param ctx core.Context
---@return string
local function format_item(action, ctx)
  local ok, reason = availability(action.available, ctx)
  local line = ("%-13s %s"):format(M.CATEGORIES[action._rank], action.label)
  if ok then return line end
  return line .. ("  [%s]"):format(reason or "unavailable")
end

---@param opts? { category?: core.ActionCategory }
function M.pick(opts)
  opts = type(opts) == "table" and opts or {}
  local ctx = M.resolve()
  local actions = M.actions(ctx)
  if opts.category then
    actions = vim.tbl_filter(function(action) return action._rank == category_order[opts.category] end, actions)
  end
  if vim.tbl_isempty(actions) then
    local what = opts.category and (opts.category:lower() .. " actions") or "actions"
    vim.notify(("No %s for this buffer"):format(what), vim.log.levels.INFO, { title = "Actions" })
    return
  end
  local names = vim.tbl_map(function(provider) return provider.name end, ctx.providers)
  vim.ui.select(actions, {
    -- This menu is searched, not browsed, so it asks for its own treatment by
    -- kind rather than taking the list-focused one every other select gets.
    kind = "action",
    prompt = (opts.category and (opts.category .. ": ") or "") .. table.concat(names, " + "),
    format_item = function(action) return format_item(action, ctx) end,
  }, function(action)
    if action then M.execute(action, ctx) end
  end)
end

function M.status()
  local ctx = M.resolve()
  local lines = {
    "buffer: " .. (ctx.file ~= "" and vim.fn.fnamemodify(ctx.file, ":~") or "[unnamed]"),
    "filetype: " .. (ctx.filetype ~= "" and ctx.filetype or "[none]"),
  }
  if vim.tbl_isempty(ctx.providers) then
    table.insert(lines, "providers: none")
  else
    table.insert(lines, "providers:")
    for _, provider in ipairs(ctx.providers) do
      local detail = ctx.details[provider.id]
      table.insert(lines, ("  %s%s"):format(provider.name, detail and (" -- " .. detail) or ""))
      vim.list_extend(lines, provider.status and provider.status(ctx) or {})
    end
  end
  for _, action in ipairs(M.actions(ctx)) do
    local ok, reason = availability(action.available, ctx)
    if not ok then table.insert(lines, ("  unavailable %s: %s"):format(action.label, reason or "unknown reason")) end
  end
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "Action status" })
end

function M.setup()
  vim.api.nvim_create_user_command("Actions", M.pick, { desc = "Choose an action valid in the current context" })
  vim.api.nvim_create_user_command("ActionsRepeat", M.repeat_last, { desc = "Repeat the last action" })
  vim.api.nvim_create_user_command("ActionsStatus", M.status, { desc = "Explain the detected project and actions" })
end

return M
