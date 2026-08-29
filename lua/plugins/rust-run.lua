-- `<Leader>R` -- Rust: running, testing, and the keys that only make sense here.
--
-- The split from `rust-lsp.lua` is the same one as `cpp-lsp.lua` vs
-- `cpp-cmake.lua`: that file is what the language server knows, this file is
-- what you press.
--
-- WHY A SEPARATE PREFIX AT ALL, WHEN `<Leader>rr` ALREADY RUNS CARGO: overseer
-- ships a `cargo` template, so in any crate `<Leader>rr` already offers `cargo
-- build`, `run`, `test`, `clippy` and the rest. That is the whole-project verb,
-- and it stays the one to press for "build everything".
--
-- What it cannot do is answer "run THIS". `cargo test` runs the suite;
-- `<Leader>Rt` with the cursor in a `#[test] fn` runs that one function,
-- because rust-analyzer resolved the `--exact` filter for it. Same for a crate
-- with six binaries: `cargo run` fails with "could not determine which binary to
-- run", and `<Leader>Rr` lists them. These keys are the ones where the language
-- server knows something the build file does not.
--
-- Everything they start still goes through overseer and lands in the bottom
-- output pane -- see `user.rust_executor`, wired in below.

local prefix = "<Leader>R"

--- The `<Leader>R` keys for a Rust buffer.
---
--- Buffer-local, like the `<Leader>C` CMake keys and for the same reason:
--- globally they would be dead weight in every Python and Lua buffer, and
--- which-key would offer a Rust menu while you are editing a notebook.
---@param bufnr integer
local function set_rust_mappings(bufnr)
  require("astrocore").set_mappings({
    n = {
      [prefix] = { desc = require("astroui").get_icon("Package", 1, true) .. "Rust" },

      -- ── Running ───────────────────────────────────────────────────────────
      -- Ask rust-analyzer what is runnable at the cursor and pick from the
      -- list: the binary this file belongs to, the example, the test module,
      -- the single `#[test]`, the doctest.
      [prefix .. "r"] = { "<Cmd>RustLsp runnables<CR>", desc = "Run (pick a target)" },
      -- The bang form re-runs the last choice without the picker. This is the
      -- key you actually hold down while iterating -- deliberately `l` to
      -- match `<Leader>rl`, which is the same idea for overseer's own tasks.
      -- (They are not interchangeable: `<Leader>rl` re-runs the last task of
      -- ANY kind, this one re-runs the last *runnable*, so a `cargo build` in
      -- between does not lose your place.)
      [prefix .. "l"] = { "<Cmd>RustLsp! runnables<CR>", desc = "Re-run last (no picker)" },
      [prefix .. "t"] = { "<Cmd>RustLsp testables<CR>", desc = "Test (this fn / mod / crate)" },
      -- Builds with debug info and starts codelldb on it -- installed by
      -- `astrocommunity.pack.rust` via mason-nvim-dap, and already present
      -- because `astrocommunity.pack.cpp` asks for the same adapter. Breakpoints
      -- and stepping are the usual `<Leader>d` keys from there.
      [prefix .. "d"] = { "<Cmd>RustLsp debuggables<CR>", desc = "Debug (codelldb)" },

      -- ── Reading the error ─────────────────────────────────────────────────
      --
      -- These two are the reason a Rust-specific menu earns its place. rustc's
      -- diagnostics are not one-liners -- they are a rendered block with the
      -- source quoted, carets under the offending span, and a `help:` line
      -- underneath:
      --
      --     error[E0502]: cannot borrow `v` as mutable because it is also
      --                   borrowed as immutable
      --       --> src/main.rs:4:5
      --        |
      --      3 |     let first = &v[0];
      --        |                  - immutable borrow occurs here
      --      4 |     v.push(4);
      --        |     ^^^^^^^^^ mutable borrow occurs here
      --
      -- The LSP protocol carries only the first line of that. `renderDiagnostic`
      -- asks rust-analyzer for the full rendered text and shows it -- the part
      -- that actually tells you which two borrows are fighting.
      [prefix .. "D"] = { "<Cmd>RustLsp renderDiagnostic<CR>", desc = "Show the full rustc error" },
      -- And this is `rustc --explain E0502`: the long-form page on what the
      -- error code means in general, with examples. In a browser this is a trip
      -- to the error index; here it is one key.
      [prefix .. "x"] = { "<Cmd>RustLsp explainError<CR>", desc = "Explain this error code" },

      -- ── Looking at things ─────────────────────────────────────────────────
      -- What the macro actually generated. `#[derive(...)]`, `println!`,
      -- `tokio::main` -- all of it is code you never see, and this is how you
      -- see it.
      [prefix .. "e"] = { "<Cmd>RustLsp expandMacro<CR>", desc = "Expand macro (recursively)" },
      -- Up one level in the module tree, which is the jump `gd` cannot make:
      -- from inside `store.rs` to the `mod store;` line that declares it.
      [prefix .. "m"] = { "<Cmd>RustLsp parentModule<CR>", desc = "Go to parent module" },
      [prefix .. "c"] = { "<Cmd>RustLsp openCargo<CR>", desc = "Open Cargo.toml" },
      -- docs.rs for the symbol under the cursor, in a browser.
      [prefix .. "o"] = { "<Cmd>RustLsp openDocs<CR>", desc = "Open docs.rs for this symbol" },

      -- rust-analyzer groups its code actions -- "Extract into function",
      -- "Convert to guarded return", the whole `Import ...` family -- and the
      -- plain LSP list flattens that into thirty entries. This keeps the
      -- grouping, so you pick a category then an action.
      --
      -- IT IS NOT THE ONE WITH THE PREVIEW. `<Leader>la` is: that goes through
      -- actions-preview and shows the unified diff of what the action will do
      -- before you take it, in the same picker `<Leader>ff` uses -- including
      -- edits to files you are not looking at, which for Rust is the common
      -- case ("Insert `mod ui;`" writes to `main.rs` from inside `ui/mod.rs`).
      -- Reach for `<Leader>la` by default and for this one when the flat list
      -- is too long to read.
      [prefix .. "a"] = { "<Cmd>RustLsp codeAction<CR>", desc = "Code action (grouped, no preview)" },

      -- Move the whole item -- function, impl block, match arm -- rather than
      -- the line. `<A-j>` / `<A-k>` from mini.move are the line version and
      -- both are worth having.
      [prefix .. "j"] = { "<Cmd>RustLsp moveItem down<CR>", desc = "Move this item down" },
      [prefix .. "k"] = { "<Cmd>RustLsp moveItem up<CR>", desc = "Move this item up" },

      -- ── The one you press when it has gone wrong ──────────────────────────
      --
      -- Proc macros are compiled to a `.so` and loaded into rust-analyzer's own
      -- process. When rustc is upgraded under a running server -- or when the
      -- server and the toolchain drift apart, which is the failure mode
      -- `rust-lsp.lua` explains at length -- that library stops loading, and
      -- everything a derive generates quietly disappears: no `Serialize` impl,
      -- no `#[derive(Parser)]` methods, and errors pointing at your code. This
      -- rebuilds them without restarting the editor.
      [prefix .. "p"] = { "<Cmd>RustLsp rebuildProcMacros<CR>", desc = "Rebuild proc macros" },
    },
  }, { buffer = bufnr })
end

--- The `<Leader>R` keys for a `Cargo.toml` buffer.
---
--- Same prefix, different buffer, no collision: `Cargo.toml` is `toml`, not
--- `rust`, so these are the only Rust keys there.
---@param bufnr integer
local function set_crates_mappings(bufnr)
  local crates = require "crates"
  require("astrocore").set_mappings({
    n = {
      [prefix] = { desc = require("astroui").get_icon("Package", 1, true) .. "Crates" },

      -- The three popups. Versions is the one worth the key: it lists every
      -- published version with the ones matching your requirement marked, so
      -- "can I move to 0.30?" is a look rather than a browser tab.
      [prefix .. "v"] = { crates.show_versions_popup, desc = "All versions of this crate" },
      [prefix .. "f"] = { crates.show_features_popup, desc = "Features (and which are on)" },
      [prefix .. "d"] = { crates.show_dependencies_popup, desc = "This crate's dependencies" },

      -- UPDATE vs UPGRADE, because the distinction is the whole point:
      -- update moves to the newest version your requirement already allows
      -- (`"0.26"` -> 0.26.3), upgrade rewrites the requirement itself
      -- (`"0.26"` -> `"0.29"`) and is the one that can break the build.
      [prefix .. "u"] = { crates.update_crate, desc = "Update this crate (within its range)" },
      [prefix .. "U"] = { crates.upgrade_crate, desc = "Upgrade this crate (bump the range)" },
      [prefix .. "a"] = { crates.update_all_crates, desc = "Update all crates" },
      [prefix .. "A"] = { crates.upgrade_all_crates, desc = "Upgrade all crates" },

      [prefix .. "o"] = { crates.open_documentation, desc = "Open docs.rs for this crate" },
      [prefix .. "R"] = { crates.reload, desc = "Reload crate data (clear cache)" },
    },
    v = {
      [prefix] = { desc = require("astroui").get_icon("Package", 1, true) .. "Crates" },
      [prefix .. "u"] = { crates.update_crates, desc = "Update selected crates" },
      [prefix .. "U"] = { crates.upgrade_crates, desc = "Upgrade selected crates" },
    },
  }, { buffer = bufnr })
end

---@type LazySpec
return {
  -- ── Runnables go through overseer ───────────────────────────────────────────
  {
    "mrcjkb/rustaceanvim",
    optional = true,
    ---@param opts table
    opts = function(_, opts)
      local executor = require("user.rust_executor").executor
      opts.tools = opts.tools or {}
      -- Three slots, because rustaceanvim splits them: `executor` for a plain
      -- run, `test_executor` for a single test, `crate_test_executor` for a
      -- whole-crate `--all-targets` test run. All three want the same thing
      -- here -- the bottom output pane.
      opts.tools.executor = executor
      opts.tools.test_executor = executor
      opts.tools.crate_test_executor = executor
      return opts
    end,
  },

  -- ── `K` on a Rust buffer shows hover ACTIONS ────────────────────────────────
  --
  -- rust-analyzer's hover carries more than documentation: it comes with the
  -- links behind the type names, so `K` on a `HashMap<String, Vec<u8>>` gives
  -- you a hover you can then jump from -- into `HashMap`, or into `Vec` -- plus
  -- the "Implementations" and "References" entries. Plain `vim.lsp.buf.hover`
  -- renders the text and throws the links away.
  --
  -- Set through AstroLSP rather than the `FileType` autocmd below, because
  -- AstroLSP sets `K` itself on attach and would otherwise land on top of this.
  -- `cond` runs per client, so this only replaces `K` on buffers rust-analyzer
  -- attached to -- NOTE the client name is `rust-analyzer` with a hyphen, which
  -- is rustaceanvim's own, not lspconfig's `rust_analyzer`.
  {
    "AstroNvim/astrolsp",
    ---@type AstroLSPOpts
    opts = {
      mappings = {
        n = {
          K = {
            "<Cmd>RustLsp hover actions<CR>",
            desc = "Hover (with actions)",
            cond = function(client) return client.name == "rust-analyzer" end,
          },
        },
      },
    },
  },

  -- ── `cargo build` errors reach the quickfix list ────────────────────────────
  --
  -- THE GAP: overseer's `cargo` template supplies a Rust `errorformat` through
  -- `default_component_params`, but an errorformat is only read by a component
  -- that asks for one -- and this config's `default` alias (see `tasks.lua`)
  -- has no `on_output_quickfix` in it. So `<Leader>rr` -> `cargo build` streamed
  -- a wall of rustc into the output pane and put NOTHING in the quickfix list;
  -- `æq` had nothing to walk.
  --
  -- Every other build in this config attaches the component itself -- CMake in
  -- `cpp-cmake.lua`, the scratch-file templates in `overseer/template/`. This is
  -- the same fix for a template we do not own: a hook that adds the component
  -- to every task the `cargo` module generates. `module` matches the template's
  -- file name, so `^cargo$` catches `cargo.lua` and leaves `cargo-make.lua`
  -- alone.
  {
    "stevearc/overseer.nvim",
    optional = true,
    ---@param opts table
    opts = function(_, opts)
      require("overseer").add_template_hook({ module = "^cargo$" }, function(task_defn, util)
        util.add_component(task_defn, {
          "on_output_quickfix",
          -- Ours rather than the one the cargo template already supplies
          -- through `default_from_task`. They are the same patterns plus one:
          -- the wrapped-header fallback documented in `user.rust_executor`,
          -- without which a long `error[E0502]: ...` summary in a narrow pane
          -- produces a quickfix entry with no line to jump to. `<Leader>rr` and
          -- `<Leader>Rr` are the same compiler saying the same thing, so they
          -- get the same parsing.
          errorformat = require("user.rust_executor").errorformat,
          open = false,
          open_on_match = false,
          items_only = true,
          -- Off for the same reason as in `user.rust_executor` -- rust-analyzer
          -- already publishes these exact errors as diagnostics, and a build's
          -- copy would not clear when you fixed the line.
          set_diagnostics = false,
        })
      end)
      return opts
    end,
  },

  -- ── Where the keys get attached ─────────────────────────────────────────────
  {
    "AstroNvim/astrocore",
    ---@param opts AstroCoreOpts
    opts = function(_, opts)
      local autocmds = opts.autocmds or {}
      autocmds.rust_mappings = {
        {
          event = "FileType",
          pattern = "rust",
          desc = "Add the <Leader>R Rust mappings to Rust buffers",
          callback = function(args) set_rust_mappings(args.buf) end,
        },
        {
          event = "FileType",
          pattern = "toml",
          desc = "Add the <Leader>R crates mappings to Cargo.toml",
          callback = function(args)
            -- `toml` is every TOML file -- `pyproject.toml`, `bacon.toml`,
            -- `.taplo.toml`. crates.nvim only has anything to say about the
            -- one, and the keys would throw on the rest.
            if vim.fs.basename(vim.api.nvim_buf_get_name(args.buf)) ~= "Cargo.toml" then return end
            set_crates_mappings(args.buf)
          end,
        },
      }
      opts.autocmds = autocmds
    end,
  },
}
