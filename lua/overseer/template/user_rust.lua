-- Overseer task for a single Rust file that belongs to no crate.
--
-- THE GAP THIS FILLS: `<Leader>rr` offers what a project declares, and for Rust
-- that is overseer's `cargo` template reading `Cargo.toml`. A lone `scratch.rs`
-- in a directory declares nothing, so the picker came up empty for exactly the
-- file where "just run it" is the whole intent -- a snippet off the book, a
-- five-line check of what `iter().windows()` actually does, an Advent of Code
-- day before it gets folded into the crate.
--
-- This is the Rust twin of `user_cpp.lua`, and that file (plus `user_python.lua`
-- before it) is the one to read first: it explains why templates live under
-- `lua/overseer/template/` (overseer globs the runtimepath for them, no
-- registration call), why the project check is in the generator rather than in
-- `condition`, and why the binary goes to the cache directory instead of next
-- to the source.
--
-- WHY IT ONLY APPEARS OUTSIDE A CRATE: inside one, compiling a file on its own
-- is the wrong answer -- it has no dependencies, so the first `use serde::...`
-- fails, and `cargo` is right there. Offering it would be an entry that always
-- fails sitting above the ones that work.

--- Files that mean "a crate owns this".
---
--- `rust-project.json` is the non-cargo form: it is what a build system like
--- buck or bazel writes to tell rust-analyzer where the crates are. Rare, but
--- if one is there then a bare `rustc` is just as wrong as it is under cargo.
local PROJECT_MARKERS = { "Cargo.toml", "rust-project.json" }

--- The edition to compile a scratch file with.
---
--- WORTH BEING EXPLICIT ABOUT: bare `rustc` with no edition flag still defaults
--- to **2015**, and has since 2018 -- cargo passes the edition from
--- `Cargo.toml`, so nothing outside cargo ever gets a modern one by default.
--- On 2015 a scratch file gets `dyn`-less trait objects, the old module path
--- rules, and `async` as an ordinary identifier, so a snippet copied from
--- anywhere current fails to compile for reasons that have nothing to do with
--- the snippet.
---
--- 2024 rather than 2021 for the same reason `user_cpp.lua` picks `-std=c++23`:
--- the point of a scratch file is usually to try the new thing, and it is what
--- the newer crates here (`spined`, `adventofcode`) are already on.
local EDITION = "2024"

---@type overseer.TemplateFileProvider
return {
  name = "user_rust",
  condition = { filetype = { "rust" } },

  ---@param search {dir: string, filetype?: string}
  generator = function(search, cb)
    local file = vim.api.nvim_buf_get_name(0)
    if file == "" then return cb {} end
    if vim.bo.filetype ~= "rust" then return cb {} end
    if vim.fn.executable "rustc" ~= 1 then return cb {} end

    if not vim.tbl_isempty(vim.fs.find(PROJECT_MARKERS, { path = search.dir, upward = true, limit = 1 })) then
      return cb {}
    end

    -- Keyed by full path so two scratch files open at once do not overwrite
    -- each other's executable. rustc also drops a `.pdb`-ish pile of debug
    -- artifacts next to its output, which is the other reason this is not
    -- written beside the source.
    local bin = vim.fs.joinpath(
      vim.fn.stdpath "cache" --[[@as string]],
      "run-rust",
      vim.fn.sha256(file):sub(1, 16) .. "-" .. vim.fn.fnamemodify(file, ":t:r")
    )

    local name = ("rustc %s"):format(vim.fn.fnamemodify(file, ":t"))

    cb {
      {
        name = name,
        desc = ("compile with edition %s and run, standalone"):format(EDITION),
        tags = { "RUN" },
        builder = function()
          return {
            name = name,
            -- One shell command rather than two tasks: `&&` is what stops it
            -- running the *previous* build after a failed compile, which is the
            -- confusing outcome -- output appears, it looks like it worked, and
            -- it is answering with yesterday's code.
            --
            -- `exec` replaces the shell with the program, so `<Leader>rk`
            -- signals the program itself rather than a shell wrapping it.
            cmd = {
              "sh",
              "-c",
              -- `-g` because `<Leader>d` breakpoints are useless without it.
              -- No `-O`: a scratch file is compiled far more often than it is
              -- run, so compile time is the thing to spend less of.
              ('mkdir -p "$(dirname "$2")" && rustc --edition %s -g -o "$2" "$1" && exec "$2"'):format(EDITION),
              "sh", -- $0
              file, -- $1
              bin, -- $2
            },
            cwd = vim.fs.dirname(file),
            components = {
              -- The alias from `plugins/tasks.lua` -- this is what opens the
              -- live output pane.
              "default",
              {
                "on_output_quickfix",
                -- Shared with the runnables bridge rather than copied: rustc
                -- alone and rustc under cargo print the same diagnostics, and
                -- Neovim's default errorformat parses neither, because the
                -- message and its `--> file:line:col` are on separate lines.
                errorformat = require("user.languages.rust.executor").errorformat,
                open_on_match = false,
                items_only = true,
                -- rust-analyzer attaches to a standalone file too (it treats it
                -- as a one-file crate), so its diagnostics are already on
                -- screen and a build's copy would double them.
                set_diagnostics = false,
              },
            },
          }
        end,
      },
    }
  end,
}
