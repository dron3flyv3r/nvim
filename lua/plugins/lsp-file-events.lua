---@type LazySpec
return {
  {
    "AstroNvim/astrocore",
    ---@param opts AstroCoreOpts
    opts = function(_, opts)
      local file_events = require "user.lsp_file_events"

      local autocmds = opts.autocmds or {}
      autocmds.lsp_file_events = {
        {
          -- `BufWritePre` is the buffer's own file; `FileWritePre` is
          -- `:w elsewhere.py`, which does not touch the buffer's name and
          -- therefore fires the other pair of events entirely.
          event = { "BufWritePre", "FileWritePre" },
          desc = "Note whether this write is about to create a new file",
          callback = function(args)
            -- `<afile>` is the file being written, which for `FileWritePre` is
            -- not the same thing as the buffer's name. `:p` because it arrives
            -- relative to the cwd.
            if args.event == "BufWritePre" and vim.bo[args.buf].buftype ~= "" then return end
            file_events.mark_if_new(vim.fn.expand "<afile>:p")
          end,
        },
        {
          event = { "BufWritePost", "FileWritePost" },
          desc = "Tell language servers about a file that was just created",
          callback = function() file_events.flush_if_new(vim.fn.expand "<afile>:p") end,
        },
      }

      local python_env = require "user.languages.python.environment"
      autocmds.python_env_refresh = {
        {
          event = { "FocusGained", "TermLeave", "TermClose", "DirChanged" },
          desc = "Notice packages installed while Neovim was not looking",
          -- `check_all`, not `check`: these fire while the terminal you ran
          -- `uv add` in is still the current buffer.
          callback = function() vim.schedule(python_env.check_all) end,
        },
        {
          event = "BufEnter",
          pattern = "*.py",
          desc = "Notice packages installed since this buffer was last current",
          callback = function(args) python_env.check(args.buf) end,
        },
      }
      opts.autocmds = autocmds

      opts.commands = opts.commands or {}
      opts.commands.PythonEnvRefresh = {
        function() require("user.languages.python.environment").refresh() end,
        desc = "Re-scan this project's virtualenv for newly installed packages",
      }
    end,
  },

  {
    -- `opts_extend = { "event_handlers" }` upstream, so these are appended to
    -- AstroNvim's handlers rather than replacing them.
    "nvim-neo-tree/neo-tree.nvim",
    opts = function(_, opts)
      local file_events = require "user.lsp_file_events"

      opts.event_handlers = opts.event_handlers or {}
      vim.list_extend(opts.event_handlers, {
        -- Both of these carry the path as a bare string.
        { event = "file_added", handler = function(path) file_events.created(path) end },
        { event = "file_deleted", handler = function(path) file_events.deleted(path) end },
        -- Both of these carry `{ source, destination }`. A rename and a move
        -- are the same operation to a language server: one path stopped
        -- existing and another started.
        {
          event = "file_moved",
          handler = function(args) file_events.moved(args.source, args.destination) end,
        },
        {
          event = "file_renamed",
          handler = function(args) file_events.moved(args.source, args.destination) end,
        },
      })
      return opts
    end,
  },
}
