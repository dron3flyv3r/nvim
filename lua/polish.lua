-- ~/.config/nvim/lua/user/polish.lua

return function()
  -- Enable automatic reload when files are changed externally
  vim.opt.autoread = true

  -- Automatically check for changes when focus is gained or buffer is entered
  vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter" }, {
    command = "checktime",
  })

  -- Optional: show a message when a buffer reloads automatically
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
  end, {
    expr = true,
    silent = true,
    desc = "Next snippet field or move right",
  })

  vim.keymap.set({ "i", "s" }, "<C-h>", function()
    if luasnip.locally_jumpable(-1) then
      luasnip.jump(-1)
    else
      return "<Left>"
    end
  end, {
    expr = true,
    silent = true,
    desc = "Previous snippet field or move left",
  })

  vim.diagnostic.config {
    update_in_insert = true,

    virtual_text = {
      spacing = 2,
      source = "if_many",
      prefix = "●",
    },

    signs = true,
    underline = true,
    severity_sort = true,

    float = {
      border = "rounded",
      source = true,
    },
  }

  require("luasnip.loaders.from_vscode").load {
    paths = {
      vim.fn.stdpath "config" .. "/snippets",
    },
  }

  -- Make sure that nvim uses the entire width of the terminal with rounded borders
  vim.opt.winblend = 0
end
