-- Inlay hint filtering: the wiring. All of the reasoning is in
-- `lua/user/inlay_hints.lua`.
--
-- One spec, on AstroCore, because everything here is a mapping, a command, or a
-- one-time hook install. AstroLSP is not involved: `features.inlay_hints` in
-- `astrolsp.lua` still decides whether hints are requested at all, and this only
-- decides which of the answers get drawn. `<Leader>uH` continues to mean
-- "no hints in this buffer, right now"; `<Leader>lH` means "never this call, in
-- this project, from now on".
--
-- The `!` on the two ignore commands widens "in this project" to "anywhere".
-- It is deliberately not on the mapping: a keypress that silently edits every
-- project's behaviour is one you make by accident.
---@type LazySpec
return {
  "AstroNvim/astrocore",
  ---@param opts AstroCoreOpts
  opts = function(_, opts)
    -- Installing the handler wrap here rather than on `LspAttach` is
    -- deliberate: the handler is resolved per response, so a single install at
    -- startup covers every server, including ones already running after an
    -- `:AstroReload`. `setup` is idempotent for the same reason.
    require("user.inlay_hints").setup()

    -- `<Leader>lh` next door is AstroNvim's signature help; this is the same
    -- neighbourhood -- what the LSP is telling you about a call -- one shift
    -- key away.
    local maps = assert(opts.mappings)
    maps.n["<Leader>lH"] = {
      function() require("user.inlay_hints").ignore() end,
      desc = "Hide inlay hints for this call",
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
