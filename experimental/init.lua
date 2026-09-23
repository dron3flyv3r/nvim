if vim.fn.has "nvim-0.13" ~= 1 then
  vim.api.nvim_echo({
    { ("This config requires Neovim 0.13+, got %s.\n"):format(vim.version()), "ErrorMsg" },
    { "Install the nightly with `just setup-update-nightly`.\n", "MoreMsg" },
  }, true, {})
  vim.cmd.quit()
  return
end

vim.g.mapleader = " "
vim.g.maplocalleader = ","

require "core.options"
require("core.diagnostics").setup()
require("core.codelens").setup()
require "core.autocmds"
require("core.utf8_guard").setup()
require("core.statusline").setup()
require("core.winbar").setup()
require("core.rename").setup()
require("core.session").setup()
require("core.terminal").setup()
require("core.macros").setup()

local lazypath = vim.fn.stdpath "data" .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  local result = vim.fn.system {
    "git",
    "clone",
    "--filter=blob:none",
    "--branch=stable",
    "https://github.com/folke/lazy.nvim.git",
    lazypath,
  }
  if vim.v.shell_error ~= 0 then
    vim.api.nvim_echo({ { ("Error cloning lazy.nvim:\n%s"):format(result), "ErrorMsg" } }, true, {})
    vim.cmd.quit()
    return
  end
end
vim.opt.rtp:prepend(lazypath)

-- Language modules probe for their server binaries as they are required, which
-- is before lazy has loaded mason and run its own PATH handling.
vim.env.PATH = vim.fs.joinpath(vim.fn.stdpath "data" --[[@as string]], "mason", "bin") .. ":" .. vim.env.PATH

local lang = require "core.lang"

require("lazy").setup {
  spec = vim.list_extend({ { import = "plugins" } }, lang.specs()),
  install = { colorscheme = { "habamax" } },
  change_detection = { notify = false },
}

require("core.actions").setup()
require("core.task").setup()
require("core.cheatsheet").setup()
lang.setup()
require "core.keymaps"

local user_init = vim.fs.joinpath(vim.fn.stdpath "config" --[[@as string]], "lua", "user", "init.lua")
if vim.uv.fs_stat(user_init) then
  local ok, err = pcall(dofile, user_init)
  if not ok then vim.notify(err, vim.log.levels.ERROR, { title = "user" }) end
end
