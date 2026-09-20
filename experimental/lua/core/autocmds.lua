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

-- Indexing is silent otherwise, and a server that cannot answer yet reads as a
-- broken one. rust-analyzer emits ~28 begin/end pairs on a trivial crate, so
-- this reports at most one line per THROTTLE_MS plus a single closing message.
-- The counter dips to zero constantly between phases, so the idle message is
-- debounced rather than sent on every dip.
local THROTTLE_MS, SETTLE_MS = 400, 300
local progress = { active = 0, shown = false, title = "working", client = "LSP", last = 0 }

local function report()
  local opts = { title = progress.client, id = "lsp_progress" }
  if progress.active > 0 then
    progress.shown = true
    vim.notify(progress.title, vim.log.levels.INFO, opts)
  elseif progress.shown then
    progress.shown = false
    vim.notify("ready", vim.log.levels.INFO, opts)
  end
end

vim.api.nvim_create_autocmd("LspProgress", {
  group = augroup "lsp_progress",
  callback = function(args)
    local value = args.data and args.data.params and args.data.params.value
    if not value then return end
    if value.kind == "begin" then
      progress.active = progress.active + 1
      progress.title = value.title or progress.title
    elseif value.kind == "end" then
      progress.active = math.max(0, progress.active - 1)
    else
      return
    end

    local client = vim.lsp.get_client_by_id(args.data.client_id)
    progress.client = client and client.name or "LSP"

    local now = vim.uv.now()
    if progress.active > 0 and now - progress.last >= THROTTLE_MS then
      progress.last = now
      report()
    end

    progress.timer = progress.timer or vim.uv.new_timer()
    progress.timer:start(SETTLE_MS, 0, vim.schedule_wrap(report))
  end,
})
