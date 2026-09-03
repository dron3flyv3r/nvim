---@type LazySpec
return {
  "AstroNvim/astrocore",
  ---@param opts AstroCoreOpts
  opts = function(_, opts)
    require("user.inlay_hints").setup()

    -- `<Leader>lh` next door is AstroNvim's signature help; this is the same
    -- neighbourhood -- what the LSP is telling you about a call -- one shift
    -- key away.
    local maps = assert(opts.mappings)
    maps.n["<Leader>lH"] = {
      function() require("user.inlay_hints").toggle() end,
      desc = "Toggle inlay hints for this call",
    }

    opts.commands = opts.commands or {}
    opts.commands.InlayHintsIgnore = {
      function(args) require("user.inlay_hints").ignore(args.args, args.bang) end,
      nargs = "?",
      bang = true,
      desc = "Hide parameter hints for a callee (default: under the cursor; ! for every project)",
    }
    opts.commands.InlayHintsIgnoreFile = {
      function(args) require("user.inlay_hints").ignore_file(args.args, args.bang) end,
      nargs = "?",
      bang = true,
      desc = "Hide all inlay hints in a path or glob (default: this file; ! for every project)",
    }
    opts.commands.InlayHintsUnignore = {
      function() require("user.inlay_hints").unignore() end,
      desc = "Show inlay hints for an ignored callee or path again",
    }
    opts.commands.InlayHintsIgnored = {
      function() require("user.inlay_hints").ignored() end,
      desc = "List what inlay hints are hidden here, and where that is stored",
    }
    opts.commands.InlayHintsEdit = {
      function() require("user.inlay_hints").edit() end,
      desc = "Open the inlay hint ignore list",
    }
  end,
}
