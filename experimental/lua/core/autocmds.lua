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

vim.api.nvim_create_autocmd("LspAttach", {
  group = augroup "inlay_hints",
  callback = function(args)
    local client = vim.lsp.get_client_by_id(args.data.client_id)
    if client and client:supports_method "textDocument/inlayHint" then
      vim.lsp.inlay_hint.enable(true, { bufnr = args.buf })
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

vim.api.nvim_create_autocmd("TermClose", {
  group = augroup "terminal",
  callback = function(args)
    if vim.b[args.buf].core_terminal then require("core.terminal").on_close(args.buf) end
  end,
})
