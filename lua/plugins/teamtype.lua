-- Local-first collaboration: each peer edits real files with their own Neovim
-- setup while Teamtype merges edits and supplies shared cursors/follow mode.
---@type LazySpec
return {
  {
    "teamtype/teamtype-nvim",
    lazy = false, -- must observe ordinary file buffers from the beginning
    config = function()
      -- Runs once the plugin is on the runtimepath, which is what makes
      -- `teamtype.cursor` requirable and therefore wrappable.
      if require("user.teamtype.peers").setup() then require("user.teamtype.panel").setup() end
    end,
  },
  {
    "AstroNvim/astrocore",
    ---@param opts AstroCoreOpts
    opts = function(_, opts)
      local teamtype = require "user.teamtype"
      local panel = require "user.teamtype.panel"
      teamtype.setup()

      local maps = assert(opts.mappings)
      maps.n["<Leader>C"] = { desc = "󰙯 Collaborate" }
      maps.n["<Leader>Ch"] = { teamtype.host, desc = "Host real-file collaboration" }
      maps.n["<Leader>Cj"] = { teamtype.join, desc = "Join with invitation code" }
      maps.n["<Leader>Cy"] = { teamtype.copy_code, desc = "Copy invitation code" }
      maps.n["<Leader>Cs"] = { teamtype.stop, desc = "Stop collaboration" }
      maps.n["<Leader>Cf"] = { "<Cmd>TeamtypeFollow<CR>", desc = "Follow a peer" }
      maps.n["<Leader>Cp"] = { "<Cmd>TeamtypeJumpToCursor<CR>", desc = "Jump to a peer cursor" }
      maps.n["<Leader>Cw"] = { panel.toggle, desc = "Toggle the peer panel" }
      maps.n["<Leader>Cc"] = { function() panel.mirror { here = true } end, desc = "Follow a peer in this window" }
      maps.n["<Leader>Cm"] = { function() panel.mirror() end, desc = "Mirror a peer in a float" }
      maps.n["<Leader>CM"] = { function() panel.mirror_stop() end, desc = "Stop mirroring everywhere" }
      maps.n["<Leader>Ci"] = { "<Cmd>TeamtypeInfo<CR>", desc = "Connection information" }
      maps.n["<Leader>Cl"] = { teamtype.open_log, desc = "Daemon log" }

      opts.commands = opts.commands or {}
      opts.commands.TeamtypeHost = { teamtype.host, desc = "Share the current project with Teamtype" }
      opts.commands.TeamtypeJoin = { teamtype.join, desc = "Join a Teamtype session" }
      opts.commands.TeamtypeCopyCode = { teamtype.copy_code, desc = "Copy the current Teamtype join code" }
      opts.commands.TeamtypeStop = { teamtype.stop, desc = "Stop the Teamtype daemon started by Neovim" }
      opts.commands.TeamtypeLog = { teamtype.open_log, desc = "Show output from the Teamtype daemon" }
      opts.commands.TeamtypePeers = { panel.toggle, desc = "Toggle the panel listing where each peer is" }
      opts.commands.TeamtypeMirror =
        { function() panel.mirror() end, desc = "Pin a floating window to a peer's position" }
      opts.commands.TeamtypeMirrorHere =
        { function() panel.mirror { here = true } end, desc = "Make this window follow a peer" }
      opts.commands.TeamtypeMirrorStop =
        { function() panel.mirror_stop() end, desc = "Stop mirroring peers in every window" }
    end,
  },
}
