-- AstroCommunity: import any community modules here
-- We import this file in `lazy_setup.lua` before the `plugins/` folder.
-- This guarantees that the specs are processed before any user plugins.

---@type LazySpec
return {
  "AstroNvim/astrocommunity",

  -- Setup for langues
  { import = "astrocommunity.pack.lua" },
  { import = "astrocommunity.pack.java" },
  { import = "astrocommunity.pack.python" },
  -- import/override with your plugins folder
  -- { import = "astrocommunity.completion.copilot-lua-cmp" },
  { import = "astrocommunity.motion.mini-move" },
  -- NOTE: vim-visual-multi is configured by hand in `plugins/multicursor.lua`,
  -- not imported from astrocommunity -- see that file for why.
  { import = "astrocommunity.code-runner.overseer-nvim" },

  { import = "astrocommunity.colorscheme.onedarkpro-nvim" },
}
