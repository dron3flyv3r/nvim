-- Local-first collaboration: each peer edits real files with their own Neovim
-- setup while Teamtype merges edits and supplies shared cursors/follow mode.
---@type LazySpec
return {
  {
    "teamtype/teamtype-nvim",
    lazy = false, -- must observe ordinary file buffers from the beginning
  },
  {
    "AstroNvim/astrocore",
    ---@param opts AstroCoreOpts
    opts = function(_, opts)
      local teamtype = require "user.teamtype"
      teamtype.setup()

      local maps = assert(opts.mappings)
      maps.n["<Leader>C"] = { desc = "󰙯 Collaborate" }
      maps.n["<Leader>Ch"] = { teamtype.host, desc = "Host real-file collaboration" }
      maps.n["<Leader>Cj"] = { teamtype.join, desc = "Join with invitation code" }
      maps.n["<Leader>Cy"] = { teamtype.copy_code, desc = "Copy invitation code" }
      maps.n["<Leader>Cs"] = { teamtype.stop, desc = "Stop collaboration" }
      maps.n["<Leader>Cf"] = { "<Cmd>TeamtypeFollow<CR>", desc = "Follow a peer" }
      maps.n["<Leader>Cp"] = { "<Cmd>TeamtypeJumpToCursor<CR>", desc = "Jump to a peer cursor" }
      maps.n["<Leader>Ci"] = { "<Cmd>TeamtypeInfo<CR>", desc = "Connection information" }
      maps.n["<Leader>Cl"] = { teamtype.open_log, desc = "Daemon log" }

      opts.commands = opts.commands or {}
      opts.commands.TeamtypeHost = { teamtype.host, desc = "Share the current project with Teamtype" }
      opts.commands.TeamtypeJoin = { teamtype.join, desc = "Join a Teamtype session" }
      opts.commands.TeamtypeCopyCode = { teamtype.copy_code, desc = "Copy the current Teamtype join code" }
      opts.commands.TeamtypeStop = { teamtype.stop, desc = "Stop the Teamtype daemon started by Neovim" }
      opts.commands.TeamtypeLog = { teamtype.open_log, desc = "Show output from the Teamtype daemon" }
    end,
  },
}
