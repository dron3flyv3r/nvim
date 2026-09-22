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
          event = "FocusLost",
          desc = "Auto-save when Neovim loses focus",
          nested = true,
          callback = function() autosave.sweep() end,
        },
        {
          -- Opt-in, with the idle save: `save_while_editing` in `user/autosave.lua`.
          event = "BufLeave",
          desc = "Auto-save when leaving a buffer",
          nested = true,
          callback = function()
            if autosave.config.save_while_editing then autosave.sweep() end
          end,
        },
        {
          -- Idle save: a normal-mode edit or leaving insert mode starts a short
          -- timer; typing in insert mode never writes.
          event = { "TextChanged", "InsertLeave" },
          desc = "Auto-save after editing goes idle",
          callback = function() autosave.debounce() end,
        },
        {
          event = "CmdlineLeave",
          desc = "Tell autosave whether a quit is forced",
          callback = function() autosave.note_cmdline() end,
        },
        {
          -- Before the "No write since last change" check, so `:q` just quits.
          -- `:q!`, `ZQ` and `<C-Q>` still discard.
          event = "QuitPre",
          desc = "Auto-save before quitting",
          nested = true,
          callback = function() autosave.on_quit() end,
        },
        {
          event = "QuickFixCmdPre",
          pattern = { "make", "lmake" },
          desc = "Auto-save before :make",
          nested = true,
          callback = function() autosave.sweep() end,
        },
        {
          -- Overseer tasks are covered by the `user_autosave` component; this
          -- is the debugger's equivalent.
          event = "User",
          pattern = "LazyLoad",
          desc = "Auto-save before a debug session starts",
          callback = function(args)
            if args.data ~= "nvim-dap" then return end
            local listeners = require("dap").listeners.before
            listeners.launch.autosave = function() autosave.sweep() end
            listeners.attach.autosave = function() autosave.sweep() end
            return true
          end,
        },
        {
          event = { "BufReadPost", "BufNewFile", "BufWritePost", "FileChangedShellPost" },
          desc = "Remember the file state autosave is allowed to write over",
          callback = function(args) autosave.stamp(args.buf) end,
        },
      }
      opts.autocmds = autocmds

      if vim.g.autosave == nil then vim.g.autosave = true end

      -- `<Leader>uw` next door is wrap and is AstroNvim's; this is auto-Write.
      local maps = assert(opts.mappings)
      -- Force quits bypass the command line, so tell autosave they discard.
      maps.n["<C-Q>"] = { function() autosave.discard "q!" end, desc = "Force quit" }
      maps.n["ZQ"] = { function() autosave.discard "q!" end, desc = "Quit without saving" }
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
      local formatting = assert(opts.formatting)
      local format_on_save = assert(formatting.format_on_save)
      ---@cast format_on_save AstroLSPFormatOnSaveOpts
      format_on_save.filter = function(bufnr) return require("user.autosave").formatting_allowed(bufnr) end
      return opts
    end,
  },
}
