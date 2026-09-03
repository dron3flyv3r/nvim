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
          event = { "BufReadPost", "BufNewFile", "BufWritePost", "FileChangedShellPost" },
          desc = "Remember the file state autosave is allowed to write over",
          callback = function(args) autosave.stamp(args.buf) end,
        },
      }
      opts.autocmds = autocmds

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
      local formatting = assert(opts.formatting)
      local format_on_save = assert(formatting.format_on_save)
      ---@cast format_on_save AstroLSPFormatOnSaveOpts
      format_on_save.filter = function(bufnr) return require("user.autosave").formatting_allowed(bufnr) end
      return opts
    end,
  },
}
