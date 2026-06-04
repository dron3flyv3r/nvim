local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"

if not vim.uv.fs_stat(lazypath) then
    vim.fn.system({
        "git",
        "clone",
        "--filter=blob:none",
        "https://github.com/folke/lazy.nvim.git",
        "--branch=stable",
        lazypath,
    })
end

vim.opt.rtp:prepend(lazypath)

require("lazy").setup({
    { import = "plugins.theme" },
    { import = "plugins.which-key" },
    { import = "plugins.telescope" },
    { import = "plugins.lsp" },
    { import = "plugins.completion" },
    { import = "plugins.neo-tree" },
    { import = "plugins.bufferline" },
    { import = "plugins.trouble" },
    { import = "plugins.aerial" },
    { import = "plugins.formatting" },
    { import = "plugins.search-replace" },
    -- { import = "plugins.runner" },
    { import = "plugins.terminal" },
})