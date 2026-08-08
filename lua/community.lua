-- AstroCommunity: import any community modules here
-- We import this file in `lazy_setup.lua` before the `plugins/` folder.
-- This guarantees that the specs are processed before any user plugins.

---@type LazySpec
return {
  "AstroNvim/astrocommunity",

  -- ── Languages ─────────────────────────────────────────────────────────────
  -- Lua is here for editing this config: lua_ls + stylua + lazydev.
  { import = "astrocommunity.pack.lua" },
  -- Python, composed by hand rather than via `astrocommunity.pack.python`.
  --
  -- That bundle imports `black` and `isort` on top of `basedpyright`, and this
  -- config already has `ruff`. The result was THREE formatters racing on every
  -- save -- none-ls running black then isort, and ruff's language server
  -- formatting too. black and ruff-format disagree about some line breaks, so
  -- what landed in the file depended on who finished last.
  --
  -- One tool per job instead: ruff formats, sorts imports and lints;
  -- basedpyright does types. See `plugins/python-lsp.lua` for the overlap
  -- between the two that still had to be trimmed.
  { import = "astrocommunity.pack.python.base" }, -- treesitter, debugpy, venv-selector
  { import = "astrocommunity.pack.python.basedpyright" },
  { import = "astrocommunity.pack.python.ruff" },
  -- C/C++: clangd + clangd_extensions + cmake-tools + codelldb, and
  -- `<Leader>lw` to switch between a source file and its header.
  --
  -- clangd needs a `compile_commands.json` to do anything useful. CMake writes
  -- one to `build/` (with CMAKE_EXPORT_COMPILE_COMMANDS=ON) and clangd finds it
  -- there by itself. arduino-cli writes one to `build/cache/`, which clangd does
  -- NOT search -- those projects need a `.clangd` at their root saying:
  --
  --     CompileFlags:
  --       CompilationDatabase: build/cache
  { import = "astrocommunity.pack.cpp" },

  -- ── Editing ───────────────────────────────────────────────────────────────
  -- <A-hjkl> to move lines and selections around.
  { import = "astrocommunity.motion.mini-move" },
  -- NOTE: vim-visual-multi is configured by hand in `plugins/multicursor.lua`,
  -- not imported from astrocommunity -- see that file for why.

  -- ── Running things ────────────────────────────────────────────────────────
  -- Detects justfiles, Makefiles and CMake and turns their targets into tasks.
  -- Remapped from `<Leader>M` to `<Leader>r` in `plugins/tasks.lua`.
  { import = "astrocommunity.code-runner.overseer-nvim" },

  { import = "astrocommunity.colorscheme.onedarkpro-nvim" },
}
