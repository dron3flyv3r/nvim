-- Wiring for `user.utf8_guard`, which is where the explanation lives: invalid
-- UTF-8 in a buffer is sent verbatim in `textDocument/didChange`, and roslyn_ls
-- dies on it inside its JSON deserializer with no exit message. The guard
-- rewrites the payload only; both commands below are the only things that can
-- touch a buffer, and only when you run them.
---@type LazySpec
return {
  "AstroNvim/astrocore",
  ---@param opts AstroCoreOpts
  opts = function(_, opts)
    local guard = require "user.utf8_guard"
    guard.setup()

    opts.commands = opts.commands or {}
    opts.commands.Utf8Check = {
      function() guard.check() end,
      desc = "Report invalid UTF-8 in this buffer and jump to the first one",
    }
    opts.commands.Utf8Fix = {
      function()
        local removed = guard.fix()
        vim.notify(
          removed == 0 and "Nothing to repair; buffer is valid UTF-8"
            or ("Removed %d invalid byte%s -- check `git diff`, text may be missing"):format(
              removed,
              removed == 1 and "" or "s"
            ),
          removed == 0 and vim.log.levels.INFO or vim.log.levels.WARN,
          { title = "UTF-8 guard" }
        )
      end,
      desc = "Delete every invalid UTF-8 byte in this buffer",
    }
  end,
}
