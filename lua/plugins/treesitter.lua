-- Which treesitter parsers get installed.
--
-- WHY THE C/C++ ONES ARE LISTED HERE BY HAND, rather than coming from the
-- language pack: `astrocommunity.pack.cpp` asks for them by setting
-- `treesitter.ensure_installed` on **astrocore**, which is where that option
-- lived in an older AstroNvim. Nothing reads that key any more -- AstroNvim's
-- treesitter spec takes `ensure_installed` on the *plugin* (merged across
-- specs by `opts_extend`), so the pack's list was being written to a table no
-- one looks at. The symptom is quiet: `cpp` files fall back to regex syntax,
-- and the treesitter textobjects (`af` / `if` for a function, `ac` / `ic` for
-- a class) silently do nothing.
--
-- Check what actually got built with `:TSInstallInfo`.

-- ── WHY THERE IS NO `branch = "main"` HERE ANY MORE ──────────────────────────
--
-- It was here, added in `c1b73fb`, and it broke treesitter outright:
--
--     Failed to run `config` for nvim-treesitter
--     module 'nvim-treesitter.configs' not found
--
-- AstroNvim's spec is built on the `master` branch's module system -- it sets
-- `main = "nvim-treesitter.configs"` and its config calls
-- `require(plugin.main).setup(opts)` plus `ts.available_modules()`. The `main`
-- branch is a rewrite with a different API and no `nvim-treesitter/configs.lua`
-- at all, so that `require` could never succeed. With `config` erroring, nothing
-- got set up: no `highlight`, no `indent`, no textobjects, no `ensure_installed`
-- -- every filetype silently fell back to regex syntax.
--
-- Pinning `master` puts the plugin back on the API AstroNvim drives, and
-- `user.ts_directives` is exactly the patch that makes `master` work on Neovim
-- 0.12 -- read its header, it was written for this branch and says so.
--
-- Moving to `main` properly is a real migration: replacing AstroNvim's config
-- with `require("nvim-treesitter").setup()`, starting highlighting from a
-- `FileType` autocmd, setting `indentexpr` by hand, and redoing the textobjects
-- mappings against the new API. Worth doing one day -- `master` is archived --
-- but it is a project, not a branch name.
---@type LazySpec
return {
  {
    "nvim-treesitter/nvim-treesitter",
    opts = {
      lazy = false,
      ensure_installed = {
        "lua",
        "vim",
        -- C/C++, and the build files that drive them. `cmake` is what gives
        -- CMakeLists.txt highlighting; `make` covers Makefiles.
        "c",
        "cpp",
        "cmake",
        "make",
        -- NOTE: `c_sharp` and `hlsl` are added by `plugins/unity.lua`, which is
        -- also where the `tree-sitter` CLI they need to build comes from.
        -- `opts_extend = { "ensure_installed" }` upstream merges the two lists.
        -- add more arguments for adding more treesitter parsers
      },
    },
  },

  -- ── The other casualty of `master` on Neovim 0.12 ─────────────────────────
  --
  -- THE CRASH: on every buffer, once a cursor settled on a word,
  --
  --     vim-illuminate: An internal error has occured: false
  --     nvim-treesitter/lua/nvim-treesitter/locals.lua:286:
  --     attempt to call method 'parent' (a nil value)
  --
  -- WHY: illuminate's `treesitter` provider calls
  -- `nvim-treesitter.locals.find_definition`, which reaches
  -- `nvim-treesitter/query.lua:251`:
  --
  --     query:iter_matches(qnode, bufnr, start_row, end_row, { all = false })
  --
  -- `all = false` is the same retired contract that `user.ts_directives`
  -- exists to reinstate for query *directives* -- it asked Neovim to hand back
  -- one node per capture instead of a list. Neovim 0.12 removed the option, so
  -- every capture arrives as a table, and `locals.lua:286` does
  -- `iter_node:parent()` on it. Line 286 is a `while` loop, which is why it
  -- fires on any word rather than on something exotic.
  --
  -- `ts_directives` cannot help here: it wraps `add_directive`/`add_predicate`,
  -- and this call site is neither. Patching it would mean wrapping
  -- `iter_matches` itself for one caller, which is a large hammer aimed at a
  -- core API that every other plugin also uses.
  --
  -- THE FIX: drop the provider. illuminate tries `lsp`, then `treesitter`, then
  -- `regex`, and stops at the first that answers -- so the treesitter provider
  -- only ever ran where LSP came back empty. With `lsp` working properly again
  -- (see `plugins/lsp-bridge.lua` -- until that landed, no server's
  -- `on_attach` ran and this provider was reached constantly), `lsp` handles
  -- every buffer with a server and `regex` covers the rest.
  --
  -- `config.set` uses a shallow `tbl_extend`, so this replaces the provider
  -- list outright rather than merging into it.
  {
    "RRethy/vim-illuminate",
    optional = true,
    opts = { providers = { "lsp", "regex" } },
  },
}
