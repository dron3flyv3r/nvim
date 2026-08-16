-- Overseer task for a single C/C++ file that belongs to no project.
--
-- THE GAP THIS FILLS: `<Leader>rr` offers what a project declares, and for C++
-- that is a justfile (the ESP32 sketches), a Makefile, or -- via
-- `plugins/cpp-cmake.lua` and the `<Leader>C` keys -- a CMakeLists. A lone
-- `scratch.cpp` in a directory declares nothing, so the picker came up empty
-- for exactly the file where "just run it" is the whole intent: a snippet off
-- cppreference, a five-line check of what `std::views::chunk` actually does.
--
-- This is the C++ half of what `user_python.lua` does for Python, and that
-- file is the one to read first -- it explains why templates live under
-- `lua/overseer/template/` (overseer globs the runtimepath for them, no
-- registration call) and documents the terminal-wrapping limit that applies to
-- the quickfix parsing here too.
--
-- WHY IT ONLY APPEARS OUTSIDE A PROJECT: in a CMake tree, compiling one
-- translation unit on its own is the wrong answer -- it has no include paths,
-- no link line, and no `compile_commands.json` behind it, so it fails on the
-- first project header. Offering it there would be an entry that always fails
-- sitting above the ones that work. `condition.callback` below hides it the
-- moment a build file appears anywhere above the file.

--- Build files that mean "something else owns this file".
---
--- `.clangd` is in the list for the arduino-cli projects: they are driven by a
--- justfile, but the justfile is not always at the root that clangd uses, and
--- a `.clangd` is the marker every one of them has (see `plugins/cpp-lsp.lua`).
local PROJECT_MARKERS = {
  "CMakeLists.txt",
  "Makefile",
  "makefile",
  "GNUmakefile",
  "justfile",
  "Justfile",
  ".justfile",
  "meson.build",
  "build.ninja",
  "compile_commands.json",
  ".clangd",
}

--- Per-language compiler and standard.
---
--- The standards are the newest the installed GCC (16.1) fully supports rather
--- than the newest it accepts a flag for -- the point of a scratch file is
--- usually to try the new thing. `-Wall -Wextra` because a throwaway file is
--- where the sloppy signed/unsigned comparison lives, and `-g` because
--- `<Leader>d` breakpoints are useless without it.
local LANGUAGES = {
  cpp = { cc = "g++", std = "-std=c++23" },
  c = { cc = "gcc", std = "-std=c23" },
}

---@type overseer.TemplateFileProvider
return {
  name = "user_cpp",
  -- `condition` is deliberately only the filetype: overseer's
  -- `SearchCondition` understands `filetype`, `dir` and `tags` and NOTHING
  -- else. A `callback` here -- which is what a condition wants to be -- is not
  -- read, and is not rejected either; it is simply never called, and the
  -- entry shows up everywhere. The project check is in the generator below
  -- instead, where returning no templates has the same effect.
  condition = { filetype = vim.tbl_keys(LANGUAGES) },

  ---@param search {dir: string, filetype?: string}
  generator = function(search, cb)
    local file = vim.api.nvim_buf_get_name(0)
    if file == "" then return cb {} end
    local lang = LANGUAGES[vim.bo.filetype]
    if not lang then return cb {} end
    if vim.fn.executable(lang.cc) ~= 1 then return cb {} end

    -- `search.dir` is the directory the picker was opened from; `vim.fs.find`
    -- with `upward` walks it and its parents. Anything found means the project
    -- owns this file and a standalone compile is the wrong answer -- see the
    -- header.
    if not vim.tbl_isempty(vim.fs.find(PROJECT_MARKERS, { path = search.dir, upward = true, limit = 1 })) then
      return cb {}
    end

    -- Somewhere that is not next to the source. Dropping an untracked binary
    -- into the directory you are editing in is how `a.out` ends up committed.
    -- Keyed by full path so two scratch files open at once do not overwrite
    -- each other's executable.
    local bin = vim.fs.joinpath(
      vim.fn.stdpath "cache" --[[@as string]],
      "run-cpp",
      vim.fn.sha256(file):sub(1, 16) .. "-" .. vim.fn.fnamemodify(file, ":t:r")
    )

    local name = ("%s %s"):format(lang.cc, vim.fn.fnamemodify(file, ":t"))

    cb {
      {
        name = name,
        desc = ("compile with %s and run, standalone"):format(lang.std),
        tags = { "RUN" },
        builder = function()
          return {
            -- Without this the task is *named* after its command, and the
            -- command is a 200-character `sh -c` -- which is what the task
            -- list, the notifications and `<Leader>rl` would all show.
            name = name,
            -- One shell command rather than two tasks: `&&` is what stops it
            -- running the *previous* build after a failed compile, which is
            -- the confusing outcome -- output appears, it looks like it
            -- worked, and it is answering with yesterday's code.
            --
            -- `exec` replaces the shell with the program, so `<Leader>rk`
            -- signals the program itself rather than a shell wrapping it.
            cmd = {
              "sh",
              "-c",
              ('mkdir -p "$(dirname "$2")" && %s %s -g -Wall -Wextra -o "$2" "$1" && exec "$2"'):format(
                lang.cc,
                lang.std
              ),
              "sh", -- $0
              file, -- $1
              bin, -- $2
            },
            cwd = vim.fs.dirname(file),
            components = {
              -- The alias from `plugins/tasks.lua` -- this is what opens the
              -- live output pane. No `errorformat` override: Neovim's default
              -- already parses gcc's `file:line:col: error:`, which is the
              -- whole reason C was easy and Python needed `PYTHON_EFM`.
              "default",
              { "on_output_quickfix", open_on_match = false, items_only = true, set_diagnostics = true },
            },
          }
        end,
      },
    }
  end,
}
