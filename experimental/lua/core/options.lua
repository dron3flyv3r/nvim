local o = vim.o

o.number = true
o.relativenumber = true
o.signcolumn = "yes"
o.cursorline = true
o.scrolloff = 8
o.sidescrolloff = 8
o.wrap = false

o.expandtab = true
o.shiftwidth = 2
o.tabstop = 2
o.softtabstop = 2
o.smartindent = true

o.ignorecase = true
o.smartcase = true
o.inccommand = "split"

o.splitbelow = true
o.splitright = true

o.undofile = true
o.swapfile = false
o.writebackup = false
o.updatetime = 250
o.timeoutlen = 1000

o.termguicolors = true
o.showmode = false
o.laststatus = 3
o.confirm = true
o.mouse = "a"
o.clipboard = "unnamedplus"

-- 'autocomplete' stays off. On this nightly it corrupts the buffer when the
-- LSP is a 'complete' source: CompleteDone fires with reason "accept" while
-- nothing is selected, and the item's text edit is applied mid-typing. Typing
-- "let" yields "include_bytes!(let)". Verified independent of fuzzy,
-- autocompletedelay, preselect and commit_characters, and absent both without
-- the "o" source and with 'autocomplete' off. Re-test before turning it on.
o.complete = ".,o,w,b"
o.completeopt = "menu,menuone,noselect,popup,fuzzy"
o.winborder = "rounded"

o.foldmethod = "expr"
o.foldexpr = "v:lua.vim.treesitter.foldexpr()"
o.foldtext = ""
o.foldlevel = 99

o.list = true
o.listchars = "tab:> ,trail:·,nbsp:␣"

vim.g.netrw_banner = 0
