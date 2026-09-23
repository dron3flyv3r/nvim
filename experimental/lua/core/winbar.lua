local M = {}

local EXPR = "%{%v:lua.require'core.winbar'.render()%}"
local METHOD = "textDocument/documentSymbol"
local DEBOUNCE_MS = 300
local MAX_NAME = 40

---@class core.winbar.Symbol
---@field name string
---@field kind integer
---@field range lsp.Range
---@field children core.winbar.Symbol[]

local kind = vim.lsp.protocol.SymbolKind

---@type table<integer, { icon: string, hl: string }>
local shown_kinds = {
  [kind.Module] = { icon = "󰏗", hl = "Include" },
  [kind.Namespace] = { icon = "󰅩", hl = "Include" },
  [kind.Class] = { icon = "󰠱", hl = "Type" },
  [kind.Struct] = { icon = "󰙅", hl = "Type" },
  [kind.Interface] = { icon = "", hl = "Type" },
  [kind.Enum] = { icon = "", hl = "Type" },
  [kind.Object] = { icon = "󰅩", hl = "Type" },
  [kind.Method] = { icon = "󰊕", hl = "Function" },
  [kind.Function] = { icon = "󰊕", hl = "Function" },
  [kind.Constructor] = { icon = "", hl = "Function" },
}

---@type table<integer, core.winbar.Symbol[]>
local symbols = {}
---@type table<integer, uv.uv_timer_t>
local timers = {}
---@type table<integer, { client: vim.lsp.Client, id: integer }>
local pending = {}

---@param a_line integer
---@param a_char integer
---@param b_line integer
---@param b_char integer
---@return boolean
local function at_or_before(a_line, a_char, b_line, b_char)
  return a_line < b_line or a_line == b_line and a_char <= b_char
end

---@param range lsp.Range
---@param line integer
---@param col integer
---@return boolean
local function contains(range, line, col)
  local first, last = range.start, range["end"]
  return at_or_before(first.line, first.character, line, col) and at_or_before(line, col, last.line, last.character)
end

---@param outer lsp.Range
---@param inner lsp.Range
---@return boolean
local function encloses(outer, inner)
  return contains(outer, inner.start.line, inner.start.character)
    and contains(outer, inner["end"].line, inner["end"].character)
end

---@param items lsp.DocumentSymbol[]
---@return core.winbar.Symbol[]
local function from_tree(items)
  local result = {}
  for _, item in ipairs(items) do
    result[#result + 1] =
      { name = item.name, kind = item.kind, range = item.range, children = from_tree(item.children or {}) }
  end
  return result
end

---@param items lsp.SymbolInformation[]
---@return core.winbar.Symbol[]
local function from_flat(items)
  local flat = vim.tbl_map(
    function(item) return { name = item.name, kind = item.kind, range = item.location.range, children = {} } end,
    items
  )
  table.sort(flat, function(a, b)
    local a_start, b_start = a.range.start, b.range.start
    if a_start.line ~= b_start.line then return a_start.line < b_start.line end
    if a_start.character ~= b_start.character then return a_start.character < b_start.character end
    return encloses(a.range, b.range) and not encloses(b.range, a.range)
  end)

  local roots, stack = {}, {}
  for _, symbol in ipairs(flat) do
    while #stack > 0 and not encloses(stack[#stack].range, symbol.range) do
      stack[#stack] = nil
    end
    local parent = stack[#stack]
    table.insert(parent and parent.children or roots, symbol)
    stack[#stack + 1] = symbol
  end
  return roots
end

---@param result lsp.DocumentSymbol[]|lsp.SymbolInformation[]
---@return core.winbar.Symbol[]
local function normalize(result)
  if result[1] and result[1].location then
    return from_flat(result --[[@as lsp.SymbolInformation[] ]])
  end
  return from_tree(result --[[@as lsp.DocumentSymbol[] ]])
end

---@param tree core.winbar.Symbol[]
---@param line integer
---@param col integer
---@return core.winbar.Symbol[]
local function enclosing(tree, line, col)
  local path, level = {}, tree
  while level do
    local found
    for _, symbol in ipairs(level) do
      if contains(symbol.range, line, col) then
        found = symbol
        break
      end
    end
    if not found then break end
    if shown_kinds[found.kind] then path[#path + 1] = found end
    level = found.children
  end
  return path
end

---@param bufnr integer
function M.request(bufnr)
  local client = vim.lsp.get_clients({ bufnr = bufnr, method = METHOD })[1]
  if not client then
    symbols[bufnr] = nil
    return
  end
  symbols[bufnr] = symbols[bufnr] or {}

  local previous = pending[bufnr]
  if previous then previous.client:cancel_request(previous.id) end

  local params = { textDocument = vim.lsp.util.make_text_document_params(bufnr) }
  local ok, id = client:request(METHOD, params, function(err, result)
    pending[bufnr] = nil
    if err or not vim.api.nvim_buf_is_valid(bufnr) then return end
    symbols[bufnr] = normalize(result or {})
    vim.cmd "redrawstatus!"
  end, bufnr)
  if ok and id then pending[bufnr] = { client = client, id = id } end
end

---@param bufnr integer
function M.changed(bufnr)
  if vim.bo[bufnr].buftype ~= "" or not symbols[bufnr] then return end
  local timer = timers[bufnr]
  if not timer then
    timer = assert(vim.uv.new_timer())
    timers[bufnr] = timer
  end
  timer:start(
    DEBOUNCE_MS,
    0,
    vim.schedule_wrap(function()
      if vim.api.nvim_buf_is_valid(bufnr) then M.request(bufnr) end
    end)
  )
end

---@param client_id integer
function M.retry_empty(client_id)
  local client = vim.lsp.get_client_by_id(client_id)
  if not client then return end
  for bufnr in pairs(client.attached_buffers) do
    if symbols[bufnr] and #symbols[bufnr] == 0 then M.request(bufnr) end
  end
end

---@param bufnr integer
function M.forget(bufnr)
  local timer = timers[bufnr]
  if timer then
    timer:stop()
    timer:close()
  end
  timers[bufnr], symbols[bufnr], pending[bufnr] = nil, nil, nil
end

---@param winid integer
---@return boolean
local function wants(winid)
  if vim.api.nvim_win_get_config(winid).relative ~= "" or vim.wo[winid].diff then return false end
  local bufnr = vim.api.nvim_win_get_buf(winid)
  return vim.bo[bufnr].buftype == "" and vim.api.nvim_buf_get_name(bufnr) ~= ""
end

---@param winid integer
---@return string
local function local_winbar(winid) return vim.api.nvim_get_option_value("winbar", { win = winid, scope = "local" }) end

---@param winid integer
---@return boolean
function M.shows(winid) return local_winbar(winid) == EXPR end

---@param winid integer
function M.update(winid)
  if not vim.api.nvim_win_is_valid(winid) then return end
  local current = local_winbar(winid)
  if current ~= "" and current ~= EXPR then return end
  local value = wants(winid) and EXPR or ""
  if value ~= current then vim.api.nvim_set_option_value("winbar", value, { win = winid, scope = "local" }) end
end

function M.update_tab()
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    M.update(winid)
  end
end

---@param bufnr integer
function M.update_buffer(bufnr)
  for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
    M.update(winid)
  end
end

---@param text string
---@return string
local function escape(text) return (text:gsub("[\r\n]+", " "):gsub("%%", "%%%%")) end

---@param name string
---@return string
local function clip(name)
  if vim.fn.strchars(name) <= MAX_NAME then return name end
  return vim.fn.strcharpart(name, 0, MAX_NAME - 1) .. "…"
end

---@param bufnr integer
---@param paint fun(group: string, text: string): string
---@return string
local function path(bufnr, paint)
  local short = vim.fn.pathshorten(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":~:."))
  local dir, tail = short:match "^(.*/)([^/]*)$"
  if not dir then return paint("Title", escape(short)) end
  return paint("Comment", escape(dir)) .. paint("Title", escape(tail))
end

---@param bufnr integer
---@param paint fun(group: string, text: string): string
---@return string
local function flags(bufnr, paint)
  local out = ""
  if vim.bo[bufnr].modified then out = out .. " " .. paint("DiagnosticWarn", "●") end
  if vim.bo[bufnr].readonly then out = out .. " " .. paint("DiagnosticWarn", "") end
  return out
end

---@return string
function M.render()
  local winid = vim.g.statusline_winid
  if type(winid) ~= "number" or not vim.api.nvim_win_is_valid(winid) then winid = vim.api.nvim_get_current_win() end
  local bufnr = vim.api.nvim_win_get_buf(winid)

  local active = winid == vim.api.nvim_get_current_win()
  local function paint(group, text)
    if not active then return text end
    return ("%%#%s#%s%%#WinBar#"):format(group, text)
  end

  local parts = { path(bufnr, paint) .. flags(bufnr, paint) }
  local tree = symbols[bufnr]
  if tree then
    local cursor = vim.api.nvim_win_get_cursor(winid)
    for _, symbol in ipairs(enclosing(tree, cursor[1] - 1, cursor[2])) do
      local style = shown_kinds[symbol.kind]
      parts[#parts + 1] = paint(style.hl, style.icon .. " " .. escape(clip(symbol.name)))
    end
  end
  return "%< " .. table.concat(parts, paint("NonText", " › "))
end

function M.setup() M.update(vim.api.nvim_get_current_win()) end

return M
