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

  -- `w` skips runs of punctuation and wraps to the next line, so on a tail like
  -- `some_function())))` it leaves the line entirely. Stop at every word start
  -- and at every individual symbol instead, and never leave the line: the last
  -- stop is end of line.
  ---@param line string
  ---@param col integer 0-based byte column of the cursor
  ---@return integer next 0-based column to move to
  local function next_stop(line, col)
    for i = col + 1, #line - 1 do
      local char, prev = line:sub(i + 1, i + 1), line:sub(i, i)
      -- Whitespace is never a stop, only what follows it. Every symbol is.
      if not char:match "%s" then
        if not char:match "[%w_]" then return i end
        if not prev:match "[%w_]" then return i end
      end
    end
    return #line
  end

  vim.keymap.set({ "i", "s" }, "<C-Right>", function()
    local row, col = unpack(vim.api.nvim_win_get_cursor(0))
    vim.api.nvim_win_set_cursor(0, { row, next_stop(vim.api.nvim_get_current_line(), col) })
  end, {
    silent = true,
    desc = "Next word or symbol on this line",
  })

  vim.keymap.set({ "i", "s" }, "<C-Left>", function()
    local row, col = unpack(vim.api.nvim_win_get_cursor(0))
    local line = vim.api.nvim_get_current_line()
    -- The mirror of `next_stop`: the last stop that is still before the cursor.
    local target, at = 0, 0
    while at < col do
      local stop = next_stop(line, at)
      if stop >= col then break end
      target, at = stop, stop
    end
    vim.api.nvim_win_set_cursor(0, { row, target })
  end, {
    silent = true,
    desc = "Previous word or symbol on this line",
  })

  -- A completion placeholder should behave like an editable field. LuaSnip
  -- normally uses Select mode for that, but if another mapping leaves the
  -- field in Visual mode, a quote becomes Vim's register prefix instead of
  -- replacing the field. Change the field first, then replay the quote in
  -- Insert mode so nvim-autopairs can create its matching quote.
  for _, quote in ipairs { '"', "'" } do
    vim.keymap.set("x", quote, function()
      if not luasnip.in_snippet() then return quote end
      vim.schedule(function() vim.api.nvim_feedkeys(quote, "m", false) end)
      return "c"
    end, {
      expr = true,
      replace_keycodes = false,
      silent = true,
      desc = "Replace snippet field with a quoted value",
    })
  end

  require("luasnip.loaders.from_vscode").load {
    paths = { vim.fn.stdpath "config" .. "/snippets" },
  }

  -- Opaque floating windows; the default blend makes code underneath bleed
  -- through hover and signature popups.
  vim.opt.winblend = 0
end
