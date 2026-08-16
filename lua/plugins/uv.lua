return {
  "benomahony/uv.nvim",
  -- Optional filetype to lazy load when you open a python file
  -- ft = { python }
  -- Optional dependency, but recommended:
  -- dependencies = {
  --   "folke/snacks.nvim"
  -- or
  --   "nvim-telescope/telescope.nvim"
  -- },
  opts = {
    picker_integration = true,
    keymaps = {
      -- uv.nvim defaults to `<Leader>x`, which is AstroNvim's quickfix/
      -- diagnostics prefix -- it was squatting on `<Leader>xq` and friends.
      -- Moved to `<Leader>v` (uV, and it is where the venv commands live).
      prefix = "<Leader>v",
    },
  },

  -- WHY THIS IS NOT JUST `opts`: installing a package has to reach the language
  -- servers, or `import rich` stays underlined until you restart Neovim. The
  -- reasoning is in `user/python_env.lua`; the triggers it normally relies on
  -- are all "you came back from somewhere", and these keymaps are the one case
  -- where you never went anywhere -- `<Leader>va` runs `uv add` on a background
  -- job and leaves you in the same buffer.
  --
  -- uv.nvim has no events and no completion callback, but every one of its
  -- commands, keymaps and pickers goes through this single function, so
  -- wrapping it catches all of them at once. It stays a wrapper rather than a
  -- fork: whatever the plugin does with the job is still entirely its business.
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
      if subcommand and touches_env[subcommand] then require("user.python_env").watch() end
    end
    -- `setup` published the original under this name as well.
    _G.run_command = uv.run_command
  end,
}
