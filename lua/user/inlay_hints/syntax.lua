local M = {}

local ARGUMENT_LISTS = {
  argument_list = true,
  arguments = true,
  bracketed_argument_list = true,
}

---@param text string
---@return string? full
---@return string? last
function M.normalize(text)
  text = text:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
  text = text:gsub("^new%s+", "")
  text = text:gsub("<.->$", "")
  text = text:gsub("[!%s]+$", "")
  if text == "" then return nil end
  return text, text:match "[%w_]+$"
end

---@param bufnr integer
---@param row integer
---@param col integer
---@param from_cursor boolean?
---@return string? full
---@return string? last
function M.call_at(bufnr, row, col, from_cursor)
  local parser_ok, parser = pcall(vim.treesitter.get_parser, bufnr, nil, { error = false })
  if not parser_ok or not parser or not pcall(parser.parse, parser) then return nil end

  local ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr, pos = { row, col } })
  if not ok then return nil end

  local function name_between(call, arguments)
    if not call then return nil end
    local start_row, start_col = call:start()
    local end_row, end_col = arguments:start()
    if start_row > end_row or (start_row == end_row and start_col >= end_col) then return nil end
    local text = table.concat(vim.api.nvim_buf_get_text(bufnr, start_row, start_col, end_row, end_col, {}), " ")
    return M.normalize(text)
  end

  while node do
    if ARGUMENT_LISTS[node:type()] then return name_between(node:parent(), node) end
    if from_cursor then
      for child in node:iter_children() do
        if ARGUMENT_LISTS[child:type()] then return name_between(node, child) end
      end
    end
    node = node:parent()
  end
end

---@param label string|lsp.InlayHintLabelPart[]
---@return string
local function label_text(label)
  if type(label) == "string" then return label end
  return table.concat(vim.tbl_map(function(part) return part.value or "" end, label))
end

---@param hint lsp.InlayHint
---@return boolean
function M.is_parameter_hint(hint)
  if hint.kind == 2 then return true end
  if hint.kind == 1 then return false end
  return label_text(hint.label):match ":%s*$" ~= nil
end

return M
