return {
  "benomahony/uv.nvim",
  opts = {
    picker_integration = true,
    keymaps = {
      -- uv.nvim defaults to `<Leader>x`, which is AstroNvim's quickfix/
      -- diagnostics prefix -- it was squatting on `<Leader>xq` and friends.
      -- Moved to `<Leader>v` (uV, and it is where the venv commands live).
      prefix = "<Leader>v",
    },
  },

  config = function(_, opts)
    local uv = require "uv"
    uv.setup(opts)

    -- Subcommands that can move `site-packages`. `run` is deliberately in the
    -- list: `uv run` re-resolves the lockfile first and will install what is
    -- missing. Anything else -- `uv tree`, `uv version` -- is left alone.
    local touches_env = {
      add = true,
      remove = true,
      sync = true,
      lock = true,
      pip = true,
      venv = true,
      init = true,
      run = true,
      tool = true,
      export = false,
    }

    local run_command = uv.run_command
    ---@param cmd string
    uv.run_command = function(cmd)
      run_command(cmd)
      local subcommand = cmd:match "^%s*uv%s+([%w-]+)"
      if subcommand and touches_env[subcommand] then require("user.languages.python.environment").watch() end
    end
    -- `setup` published the original under this name as well.
    _G.run_command = uv.run_command
  end,
}
