-- The git surface that is not a diff: staging, committing, branches, and the
-- merge that `<Leader>gd` resolves but cannot finish. Diffview stays the place
-- changes are read; this is the place the repository is moved.
---@type LazySpec
return {
  {
    "NeogitOrg/neogit",
    -- Four commands, not one: `cmd = "Neogit"` would leave the other three
    -- undefined until something else happened to load the plugin.
    cmd = { "Neogit", "NeogitResetState", "NeogitLogCurrent", "NeogitCommit" },
    opts = {
      -- Stated rather than left to Neogit's auto-detection, which probes with
      -- `require` and would silently pick up whatever happens to be installed.
      integrations = { diffview = true, snacks = true },
      -- A split rather than a tab: the commit message is written against the
      -- staged diff, and a new tab hides the review it came from. The diff is
      -- shown because this is the last look at a merge before it is a commit.
      commit_editor = { kind = "split", show_staged_diff = true },
      merge_editor = { kind = "split" },
    },
  },

  {
    "AstroNvim/astrocore",
    ---@param opts AstroCoreOpts
    opts = function(_, opts)
      local maps = assert(opts.mappings)

      -- Two keys only. Everything else Neogit does is a single letter from its
      -- own status buffer -- `c` commit, `p` pull, `P` push, `l` log, `b`
      -- branch, `Z` stash -- and duplicating those here would be a second set
      -- of names for the same actions.
      maps.n["<Leader>gg"] = { "<Cmd>Neogit<CR>", desc = "Git status (Neogit)" }
      maps.n["<Leader>gm"] = { "<Cmd>Neogit merge<CR>", desc = "Merge, or continue an unfinished one" }
    end,
  },
}
