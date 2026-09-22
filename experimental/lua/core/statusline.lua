local M = {}

---@class core.statusline.Context
---@field winid integer
---@field bufnr integer
---@field width integer

---@class core.statusline.Component
---@field side? "left"|"right"
---@field order? integer
---@field min_width? integer
---@field raw? boolean text already carries statusline markup and is not escaped
---@field text fun(ctx: core.statusline.Context): string?

---@type table<string, core.statusline.Component>
local components = {}
---@type table<integer, table<string, { title: string, percentage: integer? }>>
local progress = {}

local mode_groups = {
  n = { "N", "CoreStatuslineNormal" },
  i = { "I", "CoreStatuslineInsert" },
  v = { "V", "CoreStatuslineVisual" },
  V = { "V", "CoreStatuslineVisual" },
  ["\22"] = { "V", "CoreStatuslineVisual" },
  s = { "S", "CoreStatuslineVisual" },
  S = { "S", "CoreStatuslineVisual" },
  ["\19"] = { "S", "CoreStatuslineVisual" },
  R = { "R", "CoreStatuslineReplace" },
  c = { "C", "CoreStatuslineCommand" },
  t = { "T", "CoreStatuslineTerminal" },
  ["!"] = { "!", "CoreStatuslineCommand" },
}

local mode_sources = {
  CoreStatuslineNormal = "DiagnosticInfo",
  CoreStatuslineInsert = "DiagnosticOk",
  CoreStatuslineVisual = "DiagnosticWarn",
  CoreStatuslineReplace = "DiagnosticError",
  CoreStatuslineCommand = "Special",
  CoreStatuslineTerminal = "DiagnosticHint",
}

---@param text string
---@return string
local function escape(text)
  return text:gsub("[\r\n]", " "):gsub("%%", "%%%%")
end

---@param hl string
---@param text string
---@return string
local function highlighted(hl, text) return ("%%#%s#%s%%#StatusLine#"):format(hl, escape(text)) end

---@param bufnr integer
---@return string
local function filename(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then return "[No Name]" end
  if vim.bo[bufnr].buftype ~= "" then return vim.fn.fnamemodify(name, ":t") end
  return vim.fn.pathshorten(vim.fn.fnamemodify(name, ":~:."))
end

---@param ctx core.statusline.Context
---@param side "left"|"right"
---@return string[]
local function extra_components(ctx, side)
  local selected = {}
  for name, component in pairs(components) do
    if (component.side or "left") == side and ctx.width >= (component.min_width or 0) then
      selected[#selected + 1] = { name = name, component = component }
    end
  end
  table.sort(selected, function(a, b)
    local a_order, b_order = a.component.order or 0, b.component.order or 0
    return a_order == b_order and a.name < b.name or a_order < b_order
  end)

  local result = {}
  for _, item in ipairs(selected) do
    local ok, text = pcall(item.component.text, ctx)
    if ok and text and text ~= "" then
      result[#result + 1] = item.component.raw and text or escape(text)
    end
  end
  return result
end

---@return string?
local function recording()
  local register = require("core.macros").recording()
  if register then return highlighted("DiagnosticError", " " .. register) end
end

---@param bufnr integer
---@return string?
local function diagnostics(bufnr)
  local counts = vim.diagnostic.count(bufnr)
  local result = {}
  local errors = counts[vim.diagnostic.severity.ERROR]
  local warnings = counts[vim.diagnostic.severity.WARN]
  if errors then result[#result + 1] = highlighted("DiagnosticError", " " .. errors) end
  if warnings then result[#result + 1] = highlighted("DiagnosticWarn", " " .. warnings) end
  if #result > 0 then return table.concat(result, "  ") end
end

---@param bufnr integer
---@return string?
local function lsp_status(bufnr)
  local clients = vim.lsp.get_clients { bufnr = bufnr }
  if #clients == 0 then return nil end
  table.sort(clients, function(a, b) return a.name < b.name end)

  for _, client in ipairs(clients) do
    local active = progress[client.id]
    if active then
      local tokens = vim.tbl_keys(active)
      table.sort(tokens)
      local item = active[tokens[1]]
      local text = client.name .. ": " .. item.title
      if item.percentage then text = text .. " " .. item.percentage .. "%" end
      return highlighted("DiagnosticInfo", " " .. text)
    end
  end

  local names = vim.tbl_map(function(client) return client.name end, clients)
  return highlighted("DiagnosticHint", " " .. table.concat(names, ", "))
end

---@param name string
---@param component core.statusline.Component
function M.register(name, component)
  assert(name ~= "", "statusline component name cannot be empty")
  assert(component.text, ("statusline component %q has no text function"):format(name))
  assert(component.side == nil or component.side == "left" or component.side == "right", "invalid statusline side")
  components[name] = component
  vim.cmd.redrawstatus()
end

---@param name string
function M.unregister(name)
  components[name] = nil
  vim.cmd.redrawstatus()
end

---@param args vim.api.keyset.create_autocmd.callback_args
function M.on_lsp_progress(args)
  local data = args.data
  local params = data and data.params
  local value = params and params.value
  local client_id = data and data.client_id
  if not value or not client_id then return end

  local token = tostring(params.token or "default")
  if value.kind == "end" then
    if progress[client_id] then
      progress[client_id][token] = nil
      if not next(progress[client_id]) then progress[client_id] = nil end
    end
    return
  end

  progress[client_id] = progress[client_id] or {}
  local previous = progress[client_id][token]
  progress[client_id][token] = {
    title = value.title or (previous and previous.title) or value.message or "working",
    percentage = value.percentage,
  }
end

---@param client_id integer
function M.clear_lsp_progress(client_id) progress[client_id] = nil end

function M.refresh_highlights()
  local statusline = vim.api.nvim_get_hl(0, { name = "StatusLine", link = false })
  for target, source in pairs(mode_sources) do
    local color = vim.api.nvim_get_hl(0, { name = source, link = false })
    vim.api.nvim_set_hl(0, target, { fg = color.fg, bg = statusline.bg, bold = true })
  end
end

---@return string
function M.render()
  local winid = vim.g.statusline_winid
  if type(winid) ~= "number" or not vim.api.nvim_win_is_valid(winid) then winid = vim.api.nvim_get_current_win() end
  local bufnr = vim.api.nvim_win_get_buf(winid)
  local ctx = { winid = winid, bufnr = bufnr, width = vim.api.nvim_win_get_width(winid) }
  local mode = vim.api.nvim_get_mode().mode
  local mode_item = mode_groups[mode] or mode_groups[mode:sub(1, 1)] or { "?", "CoreStatuslineCommand" }

  local left = { highlighted(mode_item[2], " " .. mode_item[1] .. " ") }
  local macro = recording()
  if macro then left[#left + 1] = macro end
  left[#left + 1] = "%<󰈙 " .. escape(filename(bufnr))
  if vim.bo[bufnr].modified then left[#left + 1] = highlighted("DiagnosticWarn", "●") end
  if vim.bo[bufnr].readonly then left[#left + 1] = highlighted("DiagnosticWarn", "") end
  vim.list_extend(left, extra_components(ctx, "left"))

  local right = extra_components(ctx, "right")
  if ctx.width >= 55 then
    local diagnostic_status = diagnostics(bufnr)
    if diagnostic_status then right[#right + 1] = diagnostic_status end
  end
  if ctx.width >= 80 then
    local server_status = lsp_status(bufnr)
    if server_status then right[#right + 1] = server_status end
  end
  right[#right + 1] = "%S"
  right[#right + 1] = "%l:%c"
  if ctx.width >= 45 then right[#right + 1] = "%p%%" end

  return table.concat(left, " ") .. "%=" .. table.concat(right, "  ") .. " "
end

function M.setup()
  M.refresh_highlights()
end

return M
