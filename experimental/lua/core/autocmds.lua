local function augroup(name) return vim.api.nvim_create_augroup("core_" .. name, { clear = true }) end

vim.api.nvim_create_autocmd("TextYankPost", {
  group = augroup "yank_highlight",
  callback = function() vim.hl.hl_op { higroup = "IncSearch", timeout = 150 } end,
})

vim.api.nvim_create_autocmd("BufWritePre", {
  group = augroup "mkdir",
  callback = function(args)
    if args.match:match "^%w%w+://" then return end
    vim.fs.mkdir(vim.fs.dirname(vim.uv.fs_realpath(args.match) or args.match), { parents = true })
  end,
})

vim.api.nvim_create_autocmd("FileType", {
  group = augroup "quickclose",
  pattern = { "help", "qf", "man", "checkhealth", "lspinfo" },
  callback = function(args)
    vim.bo[args.buf].buflisted = false
    vim.keymap.set("n", "q", "<Cmd>close<CR>", { buffer = args.buf, silent = true })
  end,
})

vim.api.nvim_create_autocmd("BufReadPost", {
  group = augroup "last_position",
  callback = function(args)
    local mark = vim.api.nvim_buf_get_mark(args.buf, '"')
    if mark[1] > 0 and mark[1] <= vim.api.nvim_buf_line_count(args.buf) then
      pcall(vim.api.nvim_win_set_cursor, 0, mark)
    end
  end,
})

vim.api.nvim_create_autocmd("VimResized", {
  group = augroup "equalize",
  callback = function() vim.cmd.wincmd "=" end,
})

vim.api.nvim_create_autocmd("CursorMovedI", {
  group = augroup "diagnostics",
  callback = function(args) require("core.diagnostics").on_insert_move(args.buf) end,
})

vim.api.nvim_create_autocmd("LspAttach", {
  group = augroup "inlay_hints",
  callback = function(args)
    local client = vim.lsp.get_client_by_id(args.data.client_id)
    if client and client:supports_method "textDocument/inlayHint" then
      vim.lsp.inlay_hint.enable(true, { bufnr = args.buf })
    end
  end,
})

local codelens_group = augroup "codelens"

---@param bufnr integer
---@return boolean
local function lens_unresolved(bufnr)
  for _, entry in ipairs(vim.lsp.codelens.get { bufnr = bufnr }) do
    if not entry.lens.command then return true end
  end
  return false
end

-- A `codeLens/resolve` answered -32801 ContentModified while the server is still
-- loading is logged and dropped, and the row is already marked current, so nothing
-- re-requests it: the lens stays blank until an edit bumps the document version.
-- Toggling is the supported way to force a fresh request, and the unresolved check
-- is what keeps this to the one server that answered too early.
vim.api.nvim_create_autocmd("LspProgress", {
  group = codelens_group,
  pattern = "end",
  callback = function(args)
    local client = vim.lsp.get_client_by_id(args.data.client_id)
    if not client or not require("core.codelens").is_enabled() then return end
    for bufnr in pairs(client.attached_buffers) do
      if vim.api.nvim_buf_is_loaded(bufnr) and lens_unresolved(bufnr) then
        vim.lsp.codelens.enable(false, { bufnr = bufnr })
        vim.lsp.codelens.enable(true, { bufnr = bufnr })
      end
    end
  end,
})

local statusline_group = augroup "statusline"

vim.api.nvim_create_autocmd("LspProgress", {
  group = statusline_group,
  callback = function(args)
    require("core.statusline").on_lsp_progress(args)
    vim.cmd.redrawstatus()
  end,
})

vim.api.nvim_create_autocmd({ "DiagnosticChanged", "LspAttach" }, {
  group = statusline_group,
  callback = function() vim.cmd.redrawstatus() end,
})

vim.api.nvim_create_autocmd("LspDetach", {
  group = statusline_group,
  callback = function(args)
    require("core.statusline").clear_lsp_progress(args.data.client_id)
    vim.cmd.redrawstatus()
  end,
})

vim.api.nvim_create_autocmd("ColorScheme", {
  group = statusline_group,
  callback = function() require("core.statusline").refresh_highlights() end,
})

local session_group = augroup "session"

vim.api.nvim_create_autocmd("StdinReadPre", {
  group = session_group,
  callback = function() require("core.session").mark_stdin() end,
})

vim.api.nvim_create_autocmd("VimEnter", {
  group = session_group,
  nested = true,
  callback = function() require("core.session").restore_on_start() end,
})

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = session_group,
  callback = function() require("core.session").save { quiet = true } end,
})

local macros_group = augroup "macros"

-- reg_recording() still answers while RecordingLeave runs, so the redraw that
-- clears the indicator has to come after the event rather than inside it.
vim.api.nvim_create_autocmd({ "RecordingEnter", "RecordingLeave" }, {
  group = macros_group,
  callback = function(args)
    if args.event == "RecordingLeave" then require("core.macros").remember(vim.v.event.regname) end
    vim.schedule(function() vim.cmd.redrawstatus() end)
  end,
})

vim.api.nvim_create_autocmd("TermClose", {
  group = augroup "terminal",
  callback = function(args)
    if vim.b[args.buf].core_terminal then require("core.terminal").on_close(args.buf) end
  end,
})
