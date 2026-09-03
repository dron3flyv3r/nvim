return function()
  -- Reload buffers whose file changed on disk -- e.g. after a `git checkout`,
  -- or after a formatter ran outside nvim.
  vim.opt.autoread = true
  vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter" }, { command = "checktime" })
  vim.api.nvim_create_autocmd("FileChangedShellPost", {
    callback = function() vim.notify("File reloaded from disk ✨", vim.log.levels.INFO, { title = "Auto Reload" }) end,
  })

  local luasnip = require "luasnip"

  vim.keymap.set({ "i", "s" }, "<C-l>", function()
    if luasnip.locally_jumpable(1) then
      luasnip.jump(1)
    else
      return "<Right>"
    end
  end, { expr = true, silent = true, desc = "Next snippet field or move right" })

  vim.keymap.set({ "i", "s" }, "<C-h>", function()
    if luasnip.locally_jumpable(-1) then
      luasnip.jump(-1)
    else
      return "<Left>"
    end
  end, { expr = true, silent = true, desc = "Previous snippet field or move left" })

  vim.keymap.set({ "i", "s" }, "<C-Right>", "<End>", {
    silent = true,
    desc = "Move to end of current line",
  })

  require("luasnip.loaders.from_vscode").load {
    paths = { vim.fn.stdpath "config" .. "/snippets" },
  }

  -- Opaque floating windows; the default blend makes code underneath bleed
  -- through hover and signature popups.
  vim.opt.winblend = 0
end
