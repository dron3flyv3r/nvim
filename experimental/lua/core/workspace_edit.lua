local M = {}

---@class core.workspace_edit.Document
---@field uri string
---@field edits lsp.TextEdit[]

---@param line string
---@param character integer
---@param encoding string
---@return integer
function M.byte_col(line, character, encoding)
  if encoding == "utf-8" then return math.min(character, #line) end
  local ok, col = pcall(vim.str_byteindex, line, encoding, character, false)
  return ok and math.min(col, #line) or #line
end

---@param edit lsp.WorkspaceEdit
---@return core.workspace_edit.Document[] documents
---@return (lsp.CreateFile|lsp.RenameFile|lsp.DeleteFile)[] operations
function M.documents(edit)
  local documents, operations, by_uri = {}, {}, {}
  local function add(uri, edits)
    local document = by_uri[uri]
    if not document then
      document = { uri = uri, edits = {} }
      by_uri[uri] = document
      documents[#documents + 1] = document
    end
    vim.list_extend(document.edits, edits)
  end

  if edit.documentChanges then
    for _, change in ipairs(edit.documentChanges) do
      if change.kind then
        operations[#operations + 1] = change
      else
        add(change.textDocument.uri, change.edits)
      end
    end
  elseif edit.changes then
    local uris = vim.tbl_keys(edit.changes)
    table.sort(uris)
    for _, uri in ipairs(uris) do
      add(uri, edit.changes[uri])
    end
  end
  return documents, operations
end

---@param uri string
---@return integer?
function M.loaded_buffer(uri)
  local name = vim.uri_to_fname(uri)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.api.nvim_buf_get_name(bufnr) == name then return bufnr end
  end
end

---@param uri string
---@return string[]
function M.lines(uri)
  local bufnr = M.loaded_buffer(uri)
  if bufnr then return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false) end
  local name = vim.uri_to_fname(uri)
  if vim.fn.filereadable(name) == 0 then return {} end
  return vim.tbl_map(function(line) return (line:gsub("\r$", "")) end, vim.fn.readfile(name))
end

---@param edits lsp.TextEdit[]
---@return lsp.TextEdit[]
function M.bottom_up(edits)
  local ordered = {}
  for index, edit in ipairs(edits) do
    ordered[index] = { index = index, edit = edit }
  end
  table.sort(ordered, function(a, b)
    local x, y = a.edit.range.start, b.edit.range.start
    if x.line ~= y.line then return x.line > y.line end
    if x.character ~= y.character then return x.character > y.character end
    return a.index > b.index
  end)
  return vim.tbl_map(function(item) return item.edit end, ordered)
end

---@param text string
---@return string
function M.normalize_text(text) return (text:gsub("\r\n?", "\n")) end

---@param snippet string
---@return string
local function snippet_text(snippet)
  local escaped = {}
  local text = snippet:gsub("\\([$}\\])", function(char)
    escaped[#escaped + 1] = char
    return "\0"
  end)
  text = text:gsub("%${%d+:([^}]*)}", "%1"):gsub("%${%d+}", ""):gsub("%$%d+", "")
  local index = 0
  return (text:gsub("%z", function()
    index = index + 1
    return escaped[index]
  end))
end

---@param edit lsp.TextEdit|{ insertTextFormat?: integer, snippet?: { value: string } }
---@return string
local function edit_text(edit)
  if edit.snippet then return snippet_text(edit.snippet.value) end
  if edit.insertTextFormat == vim.lsp.protocol.InsertTextFormat.Snippet then return snippet_text(edit.newText) end
  return edit.newText
end

---@param lines string[]
---@param edits lsp.TextEdit[]
---@param encoding string
---@return string[]
function M.apply(lines, edits, encoding)
  -- The empty line after the final newline is where a position one past the
  -- last line points, which is how servers express an append at the end.
  local result = vim.list_extend(vim.list_slice(lines), { "" })
  local function locate(position)
    local row = math.min(position.line, #result - 1)
    local character = position.line > row and math.huge or position.character
    return row, M.byte_col(result[row + 1], character, encoding)
  end

  for _, edit in ipairs(M.bottom_up(edits)) do
    local start_row, start_col = locate(edit.range.start)
    local end_row, end_col = locate(edit.range["end"])
    local joined = result[start_row + 1]:sub(1, start_col)
      .. M.normalize_text(edit_text(edit))
      .. result[end_row + 1]:sub(end_col + 1)
    local replacement = vim.split(joined, "\n", { plain = true })
    for _ = start_row, end_row do
      table.remove(result, start_row + 1)
    end
    for offset, line in ipairs(replacement) do
      table.insert(result, start_row + offset, line)
    end
  end

  if result[#result] == "" then result[#result] = nil end
  return result
end

---@param uri string
---@return string
local function display_path(uri) return vim.fn.fnamemodify(vim.uri_to_fname(uri), ":~:.") end

---@param operation lsp.CreateFile|lsp.RenameFile|lsp.DeleteFile
---@return string
function M.describe_operation(operation)
  if operation.kind == "rename" then
    return ("Renames %s → %s"):format(display_path(operation.oldUri), display_path(operation.newUri))
  elseif operation.kind == "create" then
    return "Creates " .. display_path(operation.uri)
  end
  return "Deletes " .. display_path(operation.uri)
end

---@param hunks string
---@param before string[]
---@return string
local function with_context(hunks, before)
  return (
    hunks:gsub("(@@ %-(%d+)[^@]*@@)", function(header, start)
      for row = tonumber(start) - 1, 1, -1 do
        if before[row]:match "^[%a_$]" then return header .. " " .. before[row] end
      end
    end)
  )
end

---@param edit lsp.WorkspaceEdit
---@param encoding string
---@return string? diff git-style unified diff, nil when no text changes
---@return string[] notes the file operations the diff cannot show
function M.diff(edit, encoding)
  local documents, operations = M.documents(edit)
  local out = {}
  for _, document in ipairs(documents) do
    local before = M.lines(document.uri)
    local after = M.apply(before, document.edits, encoding)
    local hunks = vim.text.diff(table.concat(before, "\n") .. "\n", table.concat(after, "\n") .. "\n", { ctxlen = 3 })
    if hunks ~= "" then
      local path = display_path(document.uri)
      vim.list_extend(out, { ("diff --git a/%s b/%s"):format(path, path), "--- a/" .. path, "+++ b/" .. path })
      out[#out + 1] = with_context(hunks --[[@as string]], before):gsub("\n$", "")
    end
  end
  return #out > 0 and table.concat(out, "\n") or nil, vim.tbl_map(M.describe_operation, operations)
end

return M
