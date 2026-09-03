-- AstroCommunity: import any community modules here
-- We import this file in `lazy_setup.lua` before the `plugins/` folder.
-- This guarantees that the specs are processed before any user plugins.

---@type LazySpec
return {
  "AstroNvim/astrocommunity",

  -- Lua is here for editing this config: lua_ls + stylua + lazydev.
  { import = "astrocommunity.pack.lua" },
  { import = "astrocommunity.pack.python.base" }, -- treesitter, debugpy, venv-selector
  { import = "astrocommunity.pack.python.basedpyright" },
  { import = "astrocommunity.pack.python.ruff" },
  { import = "astrocommunity.pack.cpp" },
  { import = "astrocommunity.pack.rust" },

  -- Detects justfiles, Makefiles and CMake and turns their targets into tasks.
  -- Project tasks feed the contextual action system under `<Leader>r`.
  { import = "astrocommunity.code-runner.overseer-nvim" },

  { import = "astrocommunity.colorscheme.onedarkpro-nvim" },
}
