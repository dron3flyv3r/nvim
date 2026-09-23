local workspace_edit = require "core.workspace_edit"

local M = {}

local METHOD = "textDocument/rename"
local SUFFIX = "_nvimrenamepreview"
local TITLE = "Rename"

---@class core.rename.Edit
---@field start_row integer
---@field start_col integer
---@field end_row integer
---@field end_col integer
---@field text string
---@field line string

---@class core.rename.Document
---@field uri string
---@field path string
---@field bufnr? integer
---@field edits core.rename.Edit[] bottom-up

---@class core.rename.State
---@field bufnr integer
---@field client_id integer
---@field params lsp.TextDocumentPositionParams
---@field old string
---@field sentinel string
---@field documents core.rename.Document[]

---@type core.rename.State?
local state

---@param message string
---@param level? integer
local function notify(message, level) vim.notify(message, level or vim.log.levels.INFO, { title = TITLE }) end

---@param client vim.lsp.Client
---@param uri string
---@param edits lsp.TextEdit[]
---@return core.rename.Document
local function prepare_document(client, uri, edits)
  local lines = workspace_edit.lines(uri)
  local function locate(position)
    local line = lines[position.line + 1] or ""
    return position.line, workspace_edit.byte_col(line, position.character, client.offset_encoding)
  end

  local prepared = {}
  for _, edit in ipairs(workspace_edit.bottom_up(edits)) do
    local start_row, start_col = locate(edit.range.start)
    local end_row, end_col = locate(edit.range["end"])
    prepared[#prepared + 1] = {
      start_row = start_row,
      start_col = start_col,
      end_row = end_row,
      end_col = end_col,
      text = workspace_edit.normalize_text(edit.newText),
      line = lines[start_row + 1] or "",
    }
  end
  return {
    uri = uri,
    path = vim.fn.fnamemodify(vim.uri_to_fname(uri), ":~:."),
    bufnr = workspace_edit.loaded_buffer(uri),
    edits = prepared,
  }
end

---@param result lsp.PrepareRenameResult
---@param bufnr integer
---@param encoding string
---@return string?
local function placeholder(result, bufnr, encoding)
  if result.placeholder then return result.placeholder end
  local range = result.range or (result.start and result)
  if not range or range.start.line ~= range["end"].line then return nil end
  local line = vim.api.nvim_buf_get_lines(bufnr, range.start.line, range.start.line + 1, false)[1] or ""
  local first = workspace_edit.byte_col(line, range.start.character, encoding)
  local last = workspace_edit.byte_col(line, range["end"].character, encoding)
  return line:sub(first + 1, last)
end

---@param bufnr integer
---@return vim.lsp.Client?
local function rename_client(bufnr) return vim.lsp.get_clients({ bufnr = bufnr, method = METHOD })[1] end

---@param client vim.lsp.Client
---@param bufnr integer
---@param params lsp.TextDocumentPositionParams
---@param old string
local function begin(client, bufnr, params, old)
  local sentinel = old .. SUFFIX
  local request = vim.tbl_extend("force", params, { newName = sentinel })
  client:request(METHOD, request, function(err, result)
    if err then return notify(err.message, vim.log.levels.ERROR) end
    if not result then return notify("Nothing to rename here", vim.log.levels.WARN) end
    if vim.api.nvim_get_current_buf() ~= bufnr or vim.api.nvim_get_mode().mode ~= "n" then return end

    local documents = {}
    for _, document in ipairs(workspace_edit.documents(result)) do
      documents[#documents + 1] = prepare_document(client, document.uri, document.edits)
    end
    state = {
      bufnr = bufnr,
      client_id = client.id,
      params = params,
      old = old,
      sentinel = sentinel,
      documents = documents,
    }
    vim.api.nvim_feedkeys(":Rename " .. old, "n", false)
  end, bufnr)
end

function M.start()
  local bufnr = vim.api.nvim_get_current_buf()
  local client = rename_client(bufnr)
  if not client then return notify("No language server here can rename", vim.log.levels.WARN) end

  local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
  local cword = vim.fn.expand "<cword>"
  if not client:supports_method("textDocument/prepareRename", bufnr) then return begin(client, bufnr, params, cword) end

  client:request("textDocument/prepareRename", params, function(err, result)
    if err then return notify(err.message, vim.log.levels.ERROR) end
    if not result then return notify("Nothing to rename here", vim.log.levels.WARN) end
    begin(client, bufnr, params, placeholder(result, bufnr, client.offset_encoding) or cword)
  end, bufnr)
end

---@param text string
---@param new string
---@return string
local function substitute(text, new) return (text:gsub(vim.pesc(state.sentinel), (new:gsub("%%", "%%%%")))) end

---@return table<integer, true>
local function visible_buffers()
  local visible = {}
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    visible[vim.api.nvim_win_get_buf(winid)] = true
  end
  return visible
end

---@param document core.rename.Document
---@param new string
---@param ns integer
local function preview_in_buffer(document, new, ns)
  for _, edit in ipairs(document.edits) do
    local lines = vim.split(substitute(edit.text, new), "\n", { plain = true })
    vim.api.nvim_buf_set_text(document.bufnr, edit.start_row, edit.start_col, edit.end_row, edit.end_col, lines)
    vim.api.nvim_buf_set_extmark(document.bufnr, ns, edit.start_row, edit.start_col, {
      end_row = edit.start_row + #lines - 1,
      end_col = #lines == 1 and edit.start_col + #lines[1] or #lines[#lines],
      hl_group = "Substitute",
    })
  end
end

---@param document core.rename.Document
---@param new string
---@return { row: integer, text: string, spans: integer[][] }[]
local function listing_rows(document, new)
  local by_row, rows = {}, {}
  for index = #document.edits, 1, -1 do
    local edit = document.edits[index]
    local row = by_row[edit.start_row]
    if not row then
      row = { row = edit.start_row, line = edit.line, edits = {} }
      by_row[edit.start_row] = row
      rows[#rows + 1] = row
    end
    row.edits[#row.edits + 1] = edit
  end

  return vim.tbl_map(function(row)
    local pieces, spans, cursor, width = {}, {}, 0, 0
    for _, edit in ipairs(row.edits) do
      local before = row.line:sub(cursor + 1, edit.start_col)
      local text = substitute(edit.text, new):match "^[^\n]*"
      pieces[#pieces + 1] = before .. text
      width = width + #before
      spans[#spans + 1] = { width, width + #text }
      width = width + #text
      cursor = edit.end_row == edit.start_row and edit.end_col or #row.line
    end
    pieces[#pieces + 1] = row.line:sub(cursor + 1)
    local text = table.concat(pieces)
    local indent = #text:match "^%s*"
    for _, span in ipairs(spans) do
      span[1], span[2] = math.max(span[1] - indent, 0), math.max(span[2] - indent, 0)
    end
    return { row = row.row, text = text:sub(indent + 1), spans = spans }
  end, rows)
end

---@param new string
---@param ns integer
---@param buf integer
local function write_listing(new, ns, buf)
  local lines, marks = {}, {}
  for _, document in ipairs(state.documents) do
    local rows = listing_rows(document, new)
    marks[#marks + 1] = { #lines, 0, -1, "Title" }
    lines[#lines + 1] = ("%s (%d)"):format(document.path, #document.edits)
    for _, row in ipairs(rows) do
      local number = ("%5d │ "):format(row.row + 1)
      marks[#marks + 1] = { #lines, 0, #number, "LineNr" }
      for _, span in ipairs(row.spans) do
        marks[#marks + 1] = { #lines, #number + span[1], #number + span[2], "Substitute" }
      end
      lines[#lines + 1] = number .. row.text
    end
  end
  local winid = vim.fn.bufwinid(buf)
  if winid ~= -1 then
    for option, value in pairs { number = false, relativenumber = false, statuscolumn = "", signcolumn = "no" } do
      vim.api.nvim_set_option_value(option, value, { win = winid, scope = "local" })
    end
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  for _, mark in ipairs(marks) do
    local row, first, last, group = mark[1], mark[2], mark[3], mark[4]
    local line_length = #lines[row + 1]
    vim.api.nvim_buf_set_extmark(buf, ns, row, first, {
      end_col = last < 0 and line_length or math.min(last, line_length),
      hl_group = group,
    })
  end
end

---@param opts vim.api.keyset.create_user_command.command_args
---@param ns integer
---@param buf? integer
---@return integer
local function preview(opts, ns, buf)
  local new = opts.args
  if not state or state.bufnr ~= vim.api.nvim_get_current_buf() or new == "" then return 0 end

  local visible, hidden = visible_buffers(), false
  for _, document in ipairs(state.documents) do
    if document.bufnr and visible[document.bufnr] and vim.api.nvim_buf_is_loaded(document.bufnr) then
      preview_in_buffer(document, new, ns)
    else
      hidden = true
    end
  end
  if not hidden then return 1 end
  if buf then write_listing(new, ns, buf) end
  return 2
end

---@param result lsp.WorkspaceEdit
---@return string
local function summary(result)
  local documents, operations = workspace_edit.documents(result)
  local count = 0
  for _, document in ipairs(documents) do
    count = count + #document.edits
  end
  local text = ("Renamed %d occurrence%s"):format(count, count == 1 and "" or "s")
  if #documents > 1 then text = text .. (" in %d files"):format(#documents) end
  for _, operation in ipairs(operations) do
    text = text .. "\n" .. workspace_edit.describe_operation(operation)
  end
  return text
end

---@param opts vim.api.keyset.create_user_command.command_args
local function run(opts)
  local bufnr = vim.api.nvim_get_current_buf()
  local prepared = state and state.bufnr == bufnr and state or nil
  state = nil

  local client = prepared and vim.lsp.get_client_by_id(prepared.client_id) or rename_client(bufnr)
  if not client then return notify("No language server here can rename", vim.log.levels.WARN) end
  if prepared and opts.args == prepared.old then return end

  local params = prepared and prepared.params or vim.lsp.util.make_position_params(0, client.offset_encoding)
  local request = vim.tbl_extend("force", params, { newName = opts.args })
  client:request(METHOD, request, function(err, result)
    if err then return notify(err.message, vim.log.levels.ERROR) end
    if not result then return notify("The server made no changes", vim.log.levels.WARN) end
    vim.lsp.util.apply_workspace_edit(result, client.offset_encoding)
    notify(summary(result))
  end, bufnr)
end

function M.leave()
  vim.schedule(function() state = nil end)
end

function M.setup()
  vim.api.nvim_create_user_command("Rename", run, {
    nargs = 1,
    preview = preview,
    desc = "Rename the symbol under the cursor, previewing every occurrence",
  })
end

return M
