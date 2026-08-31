-- Auto-save: the wiring. All of the reasoning is in `lua/user/autosave.lua`.
--
-- Two specs, because the feature touches two owners:
--
--   * AstroCore, for the triggers and the `<Leader>uW` toggle;
--   * AstroLSP, to stop an automatic write from also reformatting the line you
--     are still typing -- the one interaction that would otherwise make this
--     unusable, and the same call VS Code makes for `afterDelay`.
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
          -- VS Code's `afterDelay`. `TextChangedI` is in here on purpose: VS
          -- Code saves while you type, and with formatting held back (see
          -- `user/autosave.lua`) an insert-mode write changes nothing you can
          -- see. Both events reset the clock, so this is one write per pause,
          -- not one per keystroke.
          event = { "TextChanged", "TextChangedI" },
          desc = "Auto-save shortly after the edits stop",
          callback = function() autosave.schedule() end,
        },
        {
          -- VS Code's `onFocusChange` (the first three) and `onWindowChange`
          -- (`FocusLost` -- you alt-tabbed away). No debounce: leaving is the
          -- signal, and waiting a second after it risks the buffer being gone.
          event = { "BufLeave", "WinLeave", "InsertLeave", "FocusLost" },
          desc = "Auto-save on leaving a buffer, window, insert mode or Neovim",
          -- See the `nested` note under the `CursorHold` trigger below.
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
        {
          -- The safety net for the case this was built for: a code action
          -- edited *another* file and you have typed nothing since, so no text
          -- event has fired anywhere. Costs nothing -- `sweep` on a clean
          -- session is a loop of `modified` checks -- and fires once per idle
          -- period, after `'updatetime'`.
          event = { "CursorHold", "CursorHoldI" },
          desc = "Auto-save buffers dirtied by something other than typing",
          -- WITHOUT THIS, THE WRITE IS INVISIBLE. A `:write` run from inside an
          -- autocmd callback fires none of its own autocmds unless the outer
          -- one is `nested` (`:h autocmd-nested`) -- so an autosaved buffer got
          -- no `BufWritePost`, and therefore no `didSave` to the language
          -- servers, no `*.cs` class-name check from `unity.lua`, no new-file
          -- notification from `lsp-file-events.lua`, and no `stamp()`. The
          -- missing stamp is the one that bit: see `M.write` in
          -- `user/autosave.lua` for the measurement.
          --
          -- Every one of those consumers is cheap, idempotent and wanted on an
          -- automatic write; the one that is not -- format-on-save, which now
          -- reaches `BufWritePre` for real -- is held back by the
          -- `format_on_save.filter` installed in the AstroLSP spec below.
          --
          -- `.ipynb` is the exception and needs no guard here: `MoltenExportOutput!`
          -- is a few hundred milliseconds and `eligible()` already refuses to
          -- autosave notebooks at all.
          nested = true,
          callback = function() autosave.sweep() end,
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
