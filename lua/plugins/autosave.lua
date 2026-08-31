-- Auto-save: the wiring. All of the reasoning is in `lua/user/autosave.lua`.
--
-- Two specs, because the feature touches two owners:
--
--   * AstroCore, for the triggers and the `<Leader>uW` toggle;
--   * AstroLSP, to distinguish a passive leave/focus write from an explicit
--     write where format-on-save is expected.
--
-- The toggle is deliberately not persisted: resession saves options, not
-- globals, so every session starts with autosave on. It is *seeded* rather than
-- left unset, though -- see the `vim.g.autosave` line below.
---@type LazySpec
return {
  {
    "AstroNvim/astrocore",
    ---@param opts AstroCoreOpts
    opts = function(_, opts)
      local autosave = require "user.autosave"

      local autocmds = opts.autocmds or {}
      autocmds.autosave = {
        {
          -- Preserve Neovim's explicit buffer/file distinction while editing.
          -- A passive save happens only when leaving the buffer or application.
          event = { "BufLeave", "FocusLost" },
          desc = "Auto-save when leaving a buffer or Neovim loses focus",
          nested = true,
          callback = function() autosave.sweep() end,
        },
        {
          -- The disk-conflict guard's bookkeeping (see `user/autosave.lua`):
          -- every moment Neovim and the file on disk are known to agree.
          -- `BufReadPost` also covers the buffers an LSP workspace edit brings
          -- into being, since `bufload()` reads the file like any other open.
          event = { "BufReadPost", "BufNewFile", "BufWritePost", "FileChangedShellPost" },
          desc = "Remember the file state autosave is allowed to write over",
          callback = function(args) autosave.stamp(args.buf) end,
        },
      }
      opts.autocmds = autocmds

      -- Seed the toggle. `eligible()` treats unset as on, so leaving it nil
      -- works -- but it makes the state unreadable, and a tri-state toggle
      -- whose third state is invisible is how you get "I turned autosave ON
      -- with <Leader>uW and nothing saves": on a fresh session that press goes
      -- nil -> false, i.e. it switches the feature OFF. With the global seeded,
      -- `:AutosaveStatus` and `:lua =vim.g.autosave` both answer before you
      -- press anything, and the press itself reads as the reversal it is.
      if vim.g.autosave == nil then vim.g.autosave = true end

      -- `<Leader>uw` next door is wrap and is AstroNvim's; this is auto-Write.
      local maps = assert(opts.mappings)
      maps.n["<Leader>uW"] = {
        function() require("user.autosave").toggle() end,
        -- Named for the default so the which-key line says which way it goes.
        desc = "Toggle autosave (on by default)",
      }

      opts.commands = opts.commands or {}
      opts.commands.AutosaveToggle = {
        function() require("user.autosave").toggle() end,
        desc = "Toggle automatic saving of modified buffers",
      }
      opts.commands.AutosaveStatus = {
        function() require("user.autosave").status() end,
        desc = "Report whether this buffer is being auto-saved, and why not",
      }
    end,
  },

  {
    "AstroNvim/astrolsp",
    ---@param opts AstroLSPOpts
    opts = function(_, opts)
      -- AstroNvim's `lsp_auto_format` autocmd consults this filter before
      -- calling `vim.lsp.buf.format` (see `_astrolsp_autocmds.lua`), which
      -- makes it the supported way in: no wrapper around `:write`, and
      -- `<Leader>uf` / `<Leader>uF` still mean what they meant.
      local formatting = assert(opts.formatting)
      local format_on_save = assert(formatting.format_on_save)
      ---@cast format_on_save AstroLSPFormatOnSaveOpts
      format_on_save.filter = function(bufnr) return require("user.autosave").formatting_allowed(bufnr) end
      return opts
    end,
  },
}
