-- Rust: who runs cargo in the background, and who owns the diagnostics.
--
-- `astrocommunity.pack.rust` (imported in `community.lua`) already does the
-- structural half: rustaceanvim takes rust-analyzer over completely, and sets
-- `handlers = { rust_analyzer = false }` so AstroLSP does not start a second
-- one alongside it. This file is the tuning on top -- the running keys and the
-- Overseer bridge live next door in `rust-run.lua`.
--
-- NOTHING HERE INSTALLS rust-analyzer. It is `extra/rust-analyzer` from pacman:
--
--     sudo pacman -S rust-analyzer
--
-- and NOT Mason's, which is an upstream release binary. The reason is
-- proc macros. rust-analyzer expands them by loading the compiled `.so` the
-- crate built and calling into it, across an ABI that is not stable between
-- rustc versions. Mismatch it and every `#[derive(Serialize)]`, every
-- `#[tokio::main]`, every `clap::Parser` silently stops contributing anything:
-- the derived methods vanish from completion, the generated `main` is not seen,
-- and the errors read as if your own code were wrong. This machine's toolchain
-- is pacman's (`rust`), so rust-analyzer should be too -- they move together.
--
-- `rust-src` is also a separate pacman package and is already installed; it is
-- what makes `gd` on `Vec::push` land in the standard library source instead of
-- doing nothing.

-- ── WHO REPORTS ERRORS: rust-analyzer, or bacon-ls ──────────────────────────
--
-- Both work by running cargo over the crate and turning the output into
-- diagnostics, and running BOTH means every borrow-check error appears twice in
-- the sign column -- the exact duplication `python-lsp.lua` was written to undo,
-- and the same rule applies: one tool per job.
--
-- WHY bacon-ls WINS WHEN IT IS THERE: rust-analyzer's check blocks until cargo
-- finishes and then publishes everything at once. bacon-ls streams -- it parses
-- cargo's JSON as it arrives and publishes a partial snapshot roughly once a
-- second, so the first error shows up while the rest of the crate is still
-- compiling. On a crate the size of `finger-control` that is the difference
-- between a pause and a wait.
--
-- NOTE WHAT bacon-ls 0.29 IS, BECAUSE THE NAME NOW LIES: it no longer needs
-- `bacon`. Since 0.26 its default backend runs cargo *itself* with
-- `--message-format=json-diagnostic-rendered-ansi` and parses the stream. The
-- bacon backend -- read an export file written by a `bacon` process watching the
-- filesystem -- is still there, and is deliberately not used here: it wants a
-- `[jobs.bacon-ls]` entry in each project's `bacon.toml` and offers to write
-- that file into your repo, which is a lot of moving parts to end up in the same
-- place. `bacon` itself remains perfectly good standalone in a terminal; this
-- config just does not depend on it.
--
-- So the probe is `bacon-ls` alone, once, at startup. With it present bacon-ls
-- owns diagnostics; without it rust-analyzer keeps the job. Either way the tool
-- being run is clippy -- `astrocommunity.pack.rust` sets `check.command =
-- "clippy"` and the cargo backend below is pointed at the same thing. The
-- question is only who drives it and how the results arrive.
--
--     cargo install --locked bacon-ls
local bacon_owns_diagnostics = vim.fn.executable "bacon-ls" == 1

---@type LazySpec
return {
  -- ── GETTING THIS FILE'S SETTINGS INTO THE SERVER AT ALL ─────────────────────
  --
  -- rustaceanvim does not read rust-analyzer's configuration when it starts the
  -- server. It reads `vim.lsp.config["rust_analyzer"]` ONCE, while its own
  -- `opts` are being evaluated, and closes over whatever it found.
  --
  -- AstroLSP is what writes that entry, and it does so from `setup_servers()`
  -- inside nvim-lspconfig's `config` -- **deferred**, not synchronously. Measured
  -- here: the entry gains its `settings` roughly 200ms after nvim-lspconfig
  -- loads. rustaceanvim's `opts` run the moment IT loads, on `ft = "rust"`. So
  -- it captured an empty table, and the server started with NONE of the
  -- configuration below -- no clippy, no `files.exclude`, no `checkOnSave`.
  --
  -- The symptom is not an error. It is one line of Rust carrying FOUR
  -- diagnostics: bacon-ls reporting the mismatched type, rust-analyzer's own
  -- analysis reporting it again because `diagnostics.enable = false` never
  -- arrived, and its cargo check reporting it a third time under the `rustc`
  -- source because `checkOnSave = false` never arrived either.
  --
  -- ORDERING ALONE CANNOT FIX THIS, which is worth stating because it is the
  -- obvious thing to reach for: the write is on a timer, not on the load, so
  -- there is no plugin rustaceanvim can be made to load after that guarantees
  -- the entry is filled. The dependency below is still declared -- it is what
  -- makes AstroLSP's `on_attach` and `capabilities` reliably present on the
  -- captured table, which is how the `<Leader>l` mappings and format-on-save
  -- reach Rust buffers -- but it is not what fixes the settings.
  --
  -- What fixes the settings is asking LATER. `server.settings` may be a
  -- function, and rustaceanvim calls it when it actually starts a server, by
  -- which time AstroLSP has long finished. So the wrapper below reads
  -- `astrolsp.config` at that moment instead of trusting the capture.
  --
  -- This is not specific to anything in this file: `astrocommunity.pack.rust`'s
  -- own `check.command = "clippy"` and `files.exclude` travel the same table and
  -- were being dropped the same way.
  {
    "mrcjkb/rustaceanvim",
    optional = true,
    dependencies = { "neovim/nvim-lspconfig" },
    ---@param opts table
    opts = function(_, opts)
      opts.server = opts.server or {}
      -- The pack sets this to a function that loads a per-project
      -- `rust-analyzer.json` on top of the defaults it is handed. Keep it, and
      -- feed our settings in as those DEFAULTS rather than layering them on
      -- top of its result -- so a project that overrides `check.command` in its
      -- own file still wins, which is the entire point of that feature.
      -- ── AstroLSP's `on_attach`, for the same reason ────────────────────────
      --
      -- It rides on the same captured table as the settings, so it went missing
      -- the same way -- and its absence is louder: `on_attach` is what sets
      -- every LSP mapping in this config. Without it a Rust buffer had no `gd`,
      -- no `grr`, no `<Leader>l` menu, no format-on-save and no `K` override,
      -- while every other language had all of them. Verified by checking for
      -- `gd` on a `.rs` buffer -- it was simply not there.
      --
      -- Assigned rather than chained: rustaceanvim wraps whatever it is given
      -- with its own (`rustaceanvim/lsp/init.lua`), and the only thing that
      -- could have been captured here is AstroLSP's own wrapper -- so chaining
      -- would risk running it twice, while assigning is exactly once.
      opts.server.on_attach = function(client, bufnr) require("astrolsp").on_attach(client, bufnr) end

      -- ── DROPPING rust-analyzer's COPY OF WHAT bacon-ls ALREADY SAID ────────
      --
      -- `diagnostics.enable` is on below even when bacon-ls owns diagnostics,
      -- because rust-analyzer is the only one that can report a file no `mod`
      -- reaches -- see `user.languages.rust.diagnostics` for the measurement and the
      -- rule. This is the other half: its rustc-code diagnostics are filtered
      -- out on arrival so the overlap never reaches the sign column.
      --
      -- Only when bacon-ls is actually here. Without it rust-analyzer is the
      -- only source there is and must keep everything.
      --
      -- It wraps `textDocument/diagnostic` as well as the push method, which is
      -- the one that actually matters: rust-analyzer advertises
      -- `diagnosticProvider`, so Neovim pulls, and a filter on
      -- `publishDiagnostics` alone sits on the client and never runs.
      if bacon_owns_diagnostics then
        opts.server.handlers = require("user.languages.rust.diagnostics").install(opts.server.handlers)
      end

      local previous = opts.server.settings
      opts.server.settings = function(project_root, default_settings)
        local astrolsp_settings = vim.tbl_get(require("astrolsp").config.config, "rust_analyzer", "settings") or {}
        local defaults = require("astrocore").extend_tbl(default_settings or {}, astrolsp_settings)
        if type(previous) == "function" then return previous(project_root, defaults) end
        return require("astrocore").extend_tbl(defaults, previous or {})
      end
      return opts
    end,
  },

  {
    "AstroNvim/astrolsp",
    ---@type AstroLSPOpts
    opts = {
      -- ── WITHOUT THIS LINE, NOTHING BELOW HAS ANY EFFECT ────────────────────
      --
      -- AstroLSP only copies `config.<server>` into `vim.lsp.config` when it
      -- runs `lsp_setup` for that server, and it only does that for servers in
      -- this list. The list is filled by mason-lspconfig from what Mason has
      -- installed -- and rust-analyzer is pacman's, so Mason has never heard of
      -- it. `lsp_setup "rust_analyzer"` was therefore never called, and
      -- `vim.lsp.config.rust_analyzer` stayed empty.
      --
      -- That is not just our settings going missing. rustaceanvim builds the
      -- config it starts the server with by reading `vim.lsp.config
      -- ["rust_analyzer"]`, so an empty table means the whole AstroLSP path is
      -- bypassed: `astrocommunity.pack.rust`'s own `check.command = "clippy"`
      -- and `files.exclude` were being dropped too, silently, and the server
      -- ran on rust-analyzer's stock defaults (`cargo check`, no excludes).
      --
      -- Naming it here makes `lsp_setup` run, which writes the config. It does
      -- NOT start a second server: `lsp_setup` resolves the settings first and
      -- consults `handlers` after, and the pack sets `handlers.rust_analyzer =
      -- false`, so the "enable it" step is skipped and rustaceanvim stays the
      -- only thing that starts rust-analyzer.
      servers = { "rust_analyzer" },

      ---@diagnostic disable: missing-fields
      config = {
        -- Merged into what the pack already set (`check.command = "clippy"`,
        -- `check.extraArgs = { "--no-deps" }`, `files.exclude`), not replacing
        -- it. rustaceanvim reads this table out of `vim.lsp.config` and folds
        -- it into the settings it hands the server.
        rust_analyzer = {
          settings = {
            ["rust-analyzer"] = {
              -- `checkOnSave` is the cargo-on-`:w` shell-out, and it goes off
              -- when bacon-ls is here, because bacon-ls is doing that job.
              --
              -- `diagnostics.enable` used to go off with it. That was wrong,
              -- and the way it was wrong is worth keeping written down: a file
              -- that no `mod` declaration reaches is in no crate, so cargo
              -- never compiles it, so clippy says nothing about it, so bacon-ls
              -- publishes nothing about it -- and with this off as well the
              -- file has no diagnostics, no completion, no hover and no inlay
              -- hints, with nothing anywhere saying why. Add `src/ui/app.rs`
              -- and `src/ui/mod.rs` but forget `mod ui;` in `main.rs` and that
              -- is exactly what you get. Measured: 0 diagnostics and 0 inlay
              -- hints in `app.rs`, 16 hints in `main.rs`, same crate, same
              -- healthy server.
              --
              -- rust-analyzer knows, and says so on line 1 with a quick fix on
              -- `<Leader>la` that writes the missing `mod`:
              --
              --     unlinked-file  This file is not included in any crates...
              --
              -- The overlap that got this turned off in the first place is
              -- handled at the client instead -- see the `handlers` wrapper in
              -- the rustaceanvim spec above and the rule in
              -- `user.languages.rust.diagnostics`. rust-analyzer's rustc-code
              -- diagnostics (`E0308` and friends) are dropped on arrival when
              -- bacon-ls owns them; its own names (`unlinked-file`,
              -- `inactive-code`, the proc-macro failures) are kept, because
              -- nothing else emits them.
              --
              -- Everything else rust-analyzer does is untouched -- types,
              -- completion, inlay hints, code actions, `gd`, call hierarchy.
              checkOnSave = not bacon_owns_diagnostics,
              diagnostics = { enable = true },

              cargo = {
                -- ── THE TARGET DIRECTORY LOCK ──────────────────────────────
                --
                -- cargo takes an exclusive lock on `target/`, and
                -- rust-analyzer's check is a cargo invocation like any other.
                -- So a `<Leader>rr` -> `cargo build` started while the server
                -- happens to be checking sits there printing
                --
                --     Blocking waiting for file lock on build directory
                --
                -- until the check finishes -- and on a crate like
                -- `finger-control`, which pulls in opencv, that is not a
                -- moment. The two are triggered by the same keystroke (`:w`
                -- formats and saves, which starts the check; then you run),
                -- so it is the common case, not a rare race.
                --
                -- Giving the server its own profile gives it its own directory
                -- under `target/`, and the two never queue behind each other.
                -- The cost is real and worth stating: a second full set of
                -- build artifacts per project, which for a mid-sized
                -- dependency tree is a gigabyte or two of disk.
                --
                -- The profile does not need to exist in `Cargo.toml`. The env
                -- var is what defines it -- `CARGO_PROFILE_<NAME>_INHERITS`
                -- tells cargo to make one up that copies `dev`.
                extraEnv = { CARGO_PROFILE_RUST_ANALYZER_INHERITS = "dev" },
                -- `cargo.extraArgs` goes on EVERY cargo invocation the server
                -- makes, which is what we want -- the check, the build scripts
                -- and the proc-macro builds all have to agree on the profile
                -- or they land in different directories and rebuild each other.
                extraArgs = { "--profile", "rust-analyzer" },
              },
            },
          },
        },
      },
    },
  },

  -- ── bacon-ls, when it is installed ──────────────────────────────────────────
  --
  -- Registered by hand rather than through AstroLSP's `servers` list, for the
  -- same reason pyrefly is in `python-lsp.lua` -- read the long note there. The
  -- short version: `servers` routes through the pre-0.11 lspconfig framework,
  -- which ignores `root_markers`, finds no root, and never starts the server
  -- without logging anything. `vim.lsp.config` + `vim.lsp.enable` is Neovim's
  -- own mechanism and works.
  --
  -- Verified against bacon-ls 0.29.0: the server attaches to a Rust buffer
  -- alongside rust-analyzer, and the diagnostics on a deliberately broken crate
  -- come back with `source = "bacon-ls"` and no rust-analyzer copy beside them.
  -- Without `bacon-ls` installed the whole branch is inert -- `executable` is 0,
  -- the callback returns immediately, and rust-analyzer keeps the job.
  {
    "AstroNvim/astrocore",
    ---@param opts AstroCoreOpts
    opts = function(_, opts)
      local autocmds = opts.autocmds or {}
      autocmds.bacon_ls = {
        {
          event = "User",
          pattern = "AstroLspSetup", -- once the other servers are set up
          desc = "Register bacon-ls as Rust's diagnostics source",
          once = true,
          callback = function()
            if not bacon_owns_diagnostics then return end
            -- `cmd`, `filetypes` and `root_markers` are NOT set here:
            -- nvim-lspconfig ships `lsp/bacon_ls.lua` with all three, and
            -- `vim.lsp.config` merges onto it. (pyrefly in `python-lsp.lua`
            -- has to spell them out because it has no such entry.) Only the
            -- settings are ours.
            --
            -- WARNING IF YOU COPY SETTINGS OFF THE INTERNET: bacon-ls 0.26
            -- reorganised all of this into per-backend sections, and most
            -- examples still show the old flat form -- including the doc
            -- comment at the top of nvim-lspconfig's own `bacon_ls.lua`, which
            -- documents `runBaconInBackground` and friends. Those keys are
            -- gone; anything not under `bacon_ls.cargo.*` or `bacon_ls.bacon.*`
            -- is silently ignored, so a stale config looks like it applied.
            vim.lsp.config("bacon_ls", {
              capabilities = require("astrolsp").config.capabilities,
              settings = {
                bacon_ls = {
                  -- Run cargo directly rather than reading a `bacon` export
                  -- file. See the header. Naming it explicitly rather than
                  -- leaning on the default, because the default is resolved
                  -- from which section is present and that is easy to disturb.
                  backend = "cargo",
                  cargo = {
                    -- The same tool rust-analyzer would have run, so switching
                    -- who reports errors does not change WHICH errors.
                    command = "clippy",
                    -- `--no-deps` matches what the pack asks rust-analyzer for:
                    -- lint this crate, not the whole dependency tree.
                    --
                    -- The profile is the `target/` lock again -- see the long
                    -- note on `cargo.extraArgs` above. This is the same profile
                    -- rust-analyzer uses rather than a third one: with its
                    -- check disabled, rust-analyzer now only runs cargo at load
                    -- (metadata, build scripts), so the two editor-side tools
                    -- almost never want the directory at once -- while a
                    -- `<Leader>rr` build, which is the collision that actually
                    -- hurts, stays on `dev` and out of the way of both.
                    extraArgs = { "--no-deps", "--profile", "rust-analyzer" },
                    env = { CARGO_PROFILE_RUST_ANALYZER_INHERITS = "dev" },
                    checkOnSave = true,
                    -- How long after the last keystroke the live run below
                    -- fires. 500ms is bacon-ls's own default and is named here
                    -- because it is the knob to reach for: raise it if cargo is
                    -- audibly spinning while you type, lower it if the errors
                    -- feel late.
                    updateOnInsertDebounceMillis = 500,
                  },
                },
              },
              -- ── ERRORS WITHOUT SAVING FIRST ───────────────────────────────
              --
              -- This is what makes diagnostics track what is in the buffer
              -- rather than what is on disk. cargo cannot read an unsaved
              -- buffer, so bacon-ls hardlinks the whole workspace into a shadow
              -- tree under `target/bacon-ls-live/`, writes the dirty buffer's
              -- bytes into its copy (breaking that one hardlink, so your real
              -- file is never touched), and runs cargo there with
              -- `--remap-path-prefix` pointing back at the real paths -- so the
              -- diagnostics land on your source, not on a copy under `target/`.
              --
              -- IT HAS TO BE `init_options`, NOT `settings`, and this is a
              -- silent failure if you get it wrong: the didChange sync
              -- capability has to be advertised at initialize time, before
              -- workspace configuration arrives, so the same key under
              -- `settings` above is accepted and does nothing.
              --
              -- THE COSTS, so they are not a surprise. A third set of build
              -- artifacts on disk, next to `dev` and the `rust-analyzer`
              -- profile. A cold first run per project while the shadow tree and
              -- its cargo cache are built. And no filesystem watcher on the
              -- shadow: a file created or deleted *outside* Neovim is not seen
              -- until the server restarts (`:LspRestart bacon_ls`) -- files you
              -- edit in Neovim are fine, that is what didChange is for.
              --
              -- To go back to on-save-only, delete this one line. Everything
              -- else keeps working.
              init_options = { cargo = { updateOnInsert = true } },
            })
            vim.lsp.enable "bacon_ls"
            -- Same reason as pyrefly: `vim.lsp.enable` only re-runs `FileType`
            -- for open buffers once `VimEnter` has fired, so starting Neovim
            -- *on* a `.rs` file would leave that one buffer without
            -- diagnostics until you touched another. No-op when there is
            -- nothing to start.
            vim.schedule(function() vim.cmd.doautoall "nvim.lsp.enable FileType" end)
          end,
        },
      }

      -- rust-analyzer is not installed by anything in this config, and when it
      -- is missing rustaceanvim fails at the point you open a Rust file, in a
      -- way that reads like a plugin bug rather than a missing package. Say
      -- what to type instead.
      autocmds.rust_analyzer_missing = {
        {
          event = "FileType",
          pattern = "rust",
          desc = "Point at the pacman package when rust-analyzer is not installed",
          once = true,
          callback = function()
            if vim.fn.executable "rust-analyzer" == 1 then return end
            vim.notify(
              "rust-analyzer is not installed -- no completion, types or diagnostics.\n"
                .. "Install it with:  sudo pacman -S rust-analyzer\n"
                .. "(pacman's, not Mason's -- see plugins/rust-lsp.lua for why.)",
              vim.log.levels.WARN,
              { title = "Rust" }
            )
          end,
        },
      }

      opts.autocmds = autocmds
    end,
  },
}
