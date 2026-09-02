-- Runs after everything else has loaded. For settings that need a plugin to
-- already exist, and for nothing else.
--
-- NOTE: diagnostics are NOT configured here any more. They live in the
-- `diagnostics` table in `lua/plugins/astrocore.lua`, which AstroCore feeds to
-- `vim.diagnostic.config()`. Calling that function here as well just gave two
-- owners for one setting, with startup order deciding the winner.

return function()
  -- Reload buffers whose file changed on disk -- e.g. after a `git checkout`,
  -- or after a formatter ran outside nvim.
  vim.opt.autoread = true
  vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter" }, { command = "checktime" })
  vim.api.nvim_create_autocmd("FileChangedShellPost", {
    callback = function() vim.notify("File reloaded from disk ✨", vim.log.levels.INFO, { title = "Auto Reload" }) end,
  })

  -- Step through snippet placeholders. Falls back to a plain cursor move when
  -- there is no snippet active, so the keys are never dead.
  --
  -- These are separate from blink.cmp's <Tab>/<S-Tab>, which also jump snippet
  -- fields -- <C-l>/<C-h> work even when the completion menu is open and would
  -- otherwise eat Tab.
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

  -- Native <C-Right> means “next word”. At `call()` on the end of a line that
  -- can cross the newline looking for another word. This configuration uses it
  -- as the ergonomic counterpart to End instead: remain on this line, after
  -- its final character. Kept in Select mode as well for snippet fields.
  vim.keymap.set({ "i", "s" }, "<C-Right>", "<End>", {
    silent = true,
    desc = "Move to end of current line",
  })

  -- The hand-written snippets in `~/.config/nvim/snippets`. AstroNvim's LuaSnip
  -- config already calls `from_vscode.lazy_load()`, but that only scans the
  -- *roots* of runtimepath entries for a `package.json` -- and ours is one level
  -- down, in `snippets/`. So this directory has to be named explicitly.
  require("luasnip.loaders.from_vscode").load {
    paths = { vim.fn.stdpath "config" .. "/snippets" },
  }

  -- Opaque floating windows; the default blend makes code underneath bleed
  -- through hover and signature popups.
  vim.opt.winblend = 0
end
