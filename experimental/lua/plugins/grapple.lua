-- A short list of files worth bouncing between, scoped per git repository and
-- persisted across restarts. Deliberately coarse: it answers "the four files I
-- am living in", not "this exact line" -- marks and `<Leader>sm` still do that.
--
-- Unmaintained upstream since 2024-09-29, so the lockfile pin is the version
-- that matters. Nothing else in the config depends on it.
---@type LazySpec
return {
  "cbochs/grapple.nvim",
  -- Icons are not decoration here: `tag_content.lua` raises a hard error when
  -- this is missing and `icons` is on. snacks finds it too and uses it for
  -- picker icons, so it earns its place twice.
  dependencies = { "nvim-tree/nvim-web-devicons" },
  cmd = "Grapple",
  ---@module 'grapple'
  ---@type grapple.settings
  opts = {
    -- One list per repository rather than per branch. `git_branch` gives each
    -- feature branch its own list, which is tidier but loses the list on every
    -- checkout. Both fall back to the working directory outside a repo.
    scope = "git",
  },
  keys = {
    { "<Leader>m", function() require("grapple").toggle() end, desc = "Toggle grapple tag" },
    { "<Leader>M", function() require("grapple").toggle_tags() end, desc = "Grapple tags" },

    -- `]g`/`[g` on a Danish layout is `øg`/`æg` through the bracket aliases in
    -- core/keymaps.lua. `]m` and `]t` are taken by Neovim itself.
    { "]g", function() require("grapple").cycle_tags "next" end, desc = "Next grapple tag" },
    { "[g", function() require("grapple").cycle_tags "prev" end, desc = "Previous grapple tag" },

    { "<Leader>1", function() require("grapple").select { index = 1 } end, desc = "Grapple tag 1" },
    { "<Leader>2", function() require("grapple").select { index = 2 } end, desc = "Grapple tag 2" },
    { "<Leader>3", function() require("grapple").select { index = 3 } end, desc = "Grapple tag 3" },
    { "<Leader>4", function() require("grapple").select { index = 4 } end, desc = "Grapple tag 4" },
  },
}
