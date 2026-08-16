-- Refactoring: the operations that *rewrite* code rather than describe it --
-- moving a function body between a header and its .cpp, extracting a
-- selection into a function, renaming a symbol across the whole project.
--
-- THE THING TO UNDERSTAND FIRST: almost none of this is a missing feature.
-- clangd 22 already implements every C++ refactoring below, and has for years.
-- They are "tweaks" in clangd's vocabulary, and they arrive over the wire as
-- ordinary `textDocument/codeAction` results -- which means they were always
-- sitting in `<Leader>la`, in a flat unlabelled list, mixed in with clang-tidy
-- fixes and #include suggestions, and only present when the cursor happens to
-- be in exactly the right place. That is not a refactoring UI; it is a lucky
-- dip. An IDE's "Refactor" menu is the same operations with two properties
-- this list does not have: a stable name you can aim at, and a key you can
-- learn.
--
-- So this file is three things:
--
--   1. `<Leader>lc` -- a menu of named clangd refactorings, each on its own
--      key, each applied without a picker. No plugin; this is `code_action`
--      with a title filter.
--   2. `<Leader>la` -- the general code-action list, now showing a *diff* of
--      what each action will do before you pick it (actions-preview.nvim).
--      This matters more than it sounds: see the DefineOutline note below.
--   3. `<Leader>lr` -- rename, with the whole project's changes previewed live
--      as you type the new name (inc-rename.nvim).
--
-- WHAT IS STILL NOT AN IDE, and cannot be fixed here: renaming or moving a
-- *file* will not update the `#include`s that point at it. That job belongs to
-- the `workspace/willRenameFiles` request, AstroLSP already sends it (its
-- `file_operations` handlers, which is why `<Leader>R` "Rename file" and a
-- neo-tree move both notify the server), and clangd simply does not implement
-- it -- it advertises no `fileOperations` capability at all, so the request is
-- delivered to nobody. basedpyright does implement it, which is why renaming a
-- Python module *does* fix its importers. Until clangd grows the handler, a
-- header rename is followed by a project-wide textual replace of the include
-- path by hand.

--- Apply the one code action whose title matches, with no picker in between.
---
--- WHY MATCH ON THE TITLE rather than ask for a kind: the kind would not
--- narrow this down anyway -- it separates "a refactoring" from "a fix" and
--- nothing finer, so every entry below except one shares the single kind
--- `refactor`. And the exception is the reason not to filter on kind at all:
--- `Populate switch` is reported as `quickfix`, not `refactor`, so passing
--- `context.only = { "refactor" }` -- the obvious optimisation, and what you
--- would write from reading the LSP spec -- would make that one key silently
--- dead. The title is the only thing that actually identifies a tweak.
---
--- The patterns are Lua patterns and deliberately loose -- a distinctive
--- fragment rather than the full string. clangd's titles are user-facing
--- English that has been reworded before (`Extract subexpression to variable`
--- was once `Extract subexpression`), and a match on a fragment survives that;
--- an equality test turns into a key that silently does nothing.
---
--- ON A MISS you get Neovim's `No code actions available`, from
--- `vim.lsp.buf.code_action` -- and it is misleading, because there usually
--- *are* actions here, just not this one. Read it as "not this refactoring, not
--- at this cursor position". The usual cause is that the cursor or the
--- selection is not where the tweak wants it -- `DefineOutline` wants the
--- cursor on the function's *name*, not somewhere in its body; the two extract
--- tweaks want a selection and offer nothing from a bare cursor. The notes on
--- the individual keys below say what each one needs.
--- The message comes from inside `vim.lsp.buf`, before any of our code runs
--- again, so there is nowhere to hang a better one without reimplementing the
--- request, the `codeAction/resolve` round trip and the command execution that
--- follow it.
---@param pattern string A Lua pattern matched against the code action title
---@return function
local function refactoring(pattern)
  return function()
    vim.lsp.buf.code_action {
      -- `apply` skips the picker when exactly one action matches, which is the
      -- whole point of these keys. When two match it still asks, which is the
      -- right fallback.
      apply = true,
      filter = function(action) return (action.title or ""):find(pattern) ~= nil end,
    }
  end
end

--- True only on a buffer clangd is attached to.
---
--- The titles above are clangd's, so these keys are meaningless in a Python or
--- Lua buffer -- and worse than meaningless in which-key, which would offer a
--- "Refactor" menu whose every entry reports `No code actions available`.
--- AstroLSP evaluates `cond` per client at attach time and sets the mapping on
--- the buffer, so this is the same mechanism `<Leader>lw` (source <-> header)
--- already uses.
---@param client vim.lsp.Client
---@return boolean
local function clangd(client) return client.name == "clangd" end

---@type LazySpec
return {
  {
    "AstroNvim/astrolsp",
    ---@type AstroLSPOpts
    opts = {
      mappings = {
        n = {
          ["<Leader>lc"] = { desc = "Refactor", cond = clangd },

          -- THE TWO THE QUESTION WAS ABOUT: header <-> .cpp, both directions.
          --
          -- `o` (out-of-line) takes a function *defined* in the header and
          -- leaves the declaration behind, moving the body into the matching
          -- .cpp -- adding the `ClassName::` qualification, dropping the
          -- `inline`/`virtual`/`static` keywords that may not be repeated, and
          -- stripping default arguments. It is the operation you want after
          -- writing a method inline "just for now".
          --
          -- `i` (inline) is the exact inverse: it pulls the body out of the
          -- .cpp and back onto the declaration.
          --
          -- `o` edits TWO FILES, one of which is usually not open, and it does
          -- it silently. That is the single strongest argument for the
          -- actions-preview diff on `<Leader>la` below -- when a DefineOutline
          -- lands somewhere unexpected (clangd picks the .cpp by the same
          -- heuristic as `<Leader>lw`, so a project with an unusual layout can
          -- surprise you), the diff is where you find out before it happens
          -- rather than after. `u` undoes only the edit in the current buffer;
          -- the other file needs its own undo.
          ["<Leader>lco"] = {
            refactoring "body to out%-of%-line",
            desc = "Move function body to the .cpp",
            cond = clangd,
          },
          ["<Leader>lci"] = {
            refactoring "body to declaration",
            desc = "Move function body to the header",
            cond = clangd,
          },

          -- NOTE: extract-to-variable and extract-to-function are visual-mode
          -- only, in the `x` table below. There is deliberately no normal-mode
          -- version: clangd resolves a bare cursor to the smallest AST node
          -- under it, which inside `factor * 2 + 1` is the `*` operator, so it
          -- offers "Swap operands to *" and no extract at all. The tweak needs
          -- a range that covers a whole expression, and the only way to say
          -- which expression you meant is to select it.

          -- Class-level generation, both with the cursor on the class name.
          -- `m` writes the copy/move constructor and assignment operator
          -- declarations that the compiler would otherwise generate implicitly
          -- -- the rule-of-five boilerplate. `c` writes a constructor taking
          -- one parameter per member.
          ["<Leader>lcm"] = {
            refactoring "^Declare implicit",
            desc = "Declare implicit copy/move members",
            cond = clangd,
          },
          ["<Leader>lcc"] = { refactoring "^Define constructor", desc = "Define constructor", cond = clangd },

          -- Cursor on the `switch`: adds a `case` for every enumerator not yet
          -- handled. The one refactoring here that is genuinely faster than a
          -- human every single time.
          ["<Leader>lcs"] = { refactoring "^Populate switch", desc = "Populate switch with missing cases", cond = clangd },

          -- Cursor on `using namespace foo;`: deletes it and qualifies every
          -- name that depended on it. The cleanup for a header that acquired
          -- one by accident.
          ["<Leader>lcu"] = {
            refactoring "Remove using namespace",
            desc = "Remove using namespace, qualify names",
            cond = clangd,
          },

          -- `enum E` -> `enum class E`, qualifying the enumerators at every
          -- use site.
          ["<Leader>lce"] = { refactoring "scoped enum", desc = "Convert to scoped enum", cond = clangd },

          -- RENAME, project-wide, with a live preview.
          --
          -- The rename itself is unchanged -- `:IncRename` calls
          -- `textDocument/rename` exactly as `vim.lsp.buf.rename` did, so the
          -- correctness still comes from clangd: it renames the *symbol*, not
          -- the string, so a local `count` in another function is untouched
          -- and a comment mentioning the name is left alone. Cross-file rename
          -- is why `--background-index` is in `cpp-lsp.lua`; without an index
          -- clangd can only see the files you have open.
          --
          -- What changes is the feedback. `vim.lsp.buf.rename` prompts, then
          -- applies, and the first you see of a 40-file edit is 40 modified
          -- buffers. `:IncRename` re-runs the rename on every keystroke and
          -- renders the result through `'inccommand'` -- the occurrences
          -- highlight in place as you type, and with `inccommand = "split"`
          -- (set below) every changed line in every file appears in a preview
          -- window. `<Esc>` at that point cancels and nothing was written.
          --
          -- `expr` with `vim.fn.expand "<cword>"` is inc-rename's own recipe:
          -- it drops you on the command line with the current name pre-filled,
          -- so the common case (change one word) is an edit rather than
          -- retyping. Note it is NOT `silent` -- a silent expr mapping would
          -- hide the command line this depends on. `set_mappings` passes both
          -- flags straight through to `vim.keymap.set`.
          ["<Leader>lr"] = {
            function() return ":IncRename " .. vim.fn.expand "<cword>" end,
            expr = true,
            desc = "Rename symbol across the project (live preview)",
            cond = "textDocument/rename",
          },

          -- The general list, now with a diff. Overrides AstroNvim's plain
          -- `vim.lsp.buf.code_action` -- see the plugin spec below.
          --
          -- `actions-preview.code_actions` takes the same `range` option as the
          -- built-in and requests at the bare cursor without one, so it has the
          -- same clangd column sensitivity and gets the same widening wrapper
          -- as `<Leader>xa`. See `user/quick_fix.lua`.
          ["<Leader>la"] = {
            function() require("user.quick_fix").code_action(require("actions-preview").code_actions)() end,
            desc = "LSP code action (preview diff)",
            cond = "textDocument/codeAction",
          },
        },

        x = {
          ["<Leader>lc"] = { desc = "Refactor", cond = clangd },

          -- The two that need a selection to mean anything.
          --
          -- `f` is the big one: it works out which locals the selected
          -- statements read, turns those into the parameter list of a new
          -- function, and leaves a call behind.
          --
          -- THE REFUSAL YOU WILL ACTUALLY HIT (and it reads as
          -- `No code actions available`, per the note above) is a selection
          -- that *declares* a variable used after it. Given
          --
          --     int x = a + b;
          --     int y = x * 2;
          --     return y;
          --
          -- neither the first line nor the first two can be extracted, because
          -- the extracted function would have to hand `x` (or `y`) back and
          -- clangd will not invent a return value or an out-parameter to do
          -- it. Selections that only *read* locals extract fine. The other
          -- refusals are a selection that is not a whole number of statements,
          -- and control flow that would escape it (a `break` whose loop is
          -- outside the selection, a `return` in the middle).
          --
          -- `vim.lsp.buf.code_action` reads the visual selection by itself: it
          -- checks `nvim_get_mode()` and, in `v` or `V`, builds the range from
          -- the marks. Nothing extra to pass, and the mode is still visual
          -- when a mapping's callback runs.
          ["<Leader>lcf"] = { refactoring "^Extract to function", desc = "Extract selection to function", cond = clangd },
          ["<Leader>lcv"] = {
            refactoring "^Extract subexpression",
            desc = "Extract selection to variable",
            cond = clangd,
          },

          ["<Leader>la"] = {
            function() require("actions-preview").code_actions() end,
            desc = "LSP code action (preview diff)",
            cond = "textDocument/codeAction",
          },
        },
      },
    },
  },

  {
    -- Code actions as a picker with a unified diff in the preview pane,
    -- instead of a list of titles you accept on faith.
    --
    -- Worth it here specifically because the C++ refactorings are the
    -- large-blast-radius ones -- DefineOutline writes to a file you are not
    -- looking at, RemoveUsingNamespace can touch a hundred lines -- and
    -- because several clang-tidy fixes have titles that do not distinguish
    -- between doing the safe thing and doing the drastic one.
    "aznhe21/actions-preview.nvim",
    -- Loaded by the `<Leader>la` mappings above, which are set on LspAttach.
    lazy = true,
    opts = {
      -- Default is `{ "telescope", "minipick", "snacks", "nui" }` and it takes
      -- the first one that is installed -- which would already resolve to
      -- snacks here. Naming it anyway so that installing telescope for some
      -- unrelated reason does not quietly move this UI somewhere else.
      -- `nui` stays as the fallback; it is the plugin's own float and needs
      -- nothing from the picker.
      backend = { "snacks", "nui" },
      -- `highlight_command` (delta / diff-so-fancy) is deliberately left
      -- empty. Setting it routes the preview through `vim.fn.termopen`, which
      -- is deprecated on Neovim 0.11+, for syntax colouring that snacks'
      -- built-in `diff` treatment already provides.
    },
  },

  {
    -- `:IncRename`, driving `textDocument/rename` through `'inccommand'`.
    "smjonas/inc-rename.nvim",
    cmd = "IncRename",
    opts = {},
    dependencies = {
      {
        "AstroNvim/astrocore",
        ---@type AstroCoreOpts
        opts = {
          options = {
            opt = {
              -- Neovim's default is `nosplit`: a `:s` previews by highlighting
              -- matches in the current window. `split` adds a preview window
              -- listing every changed line, which is what turns an inc-rename
              -- into something you can actually check before committing to --
              -- the whole point is seeing the twelve files it will touch.
              --
              -- This is a global option, so ordinary `:%s/foo/bar/` gets the
              -- same preview window. That is the intended trade and generally
              -- an improvement, but it is a visible change to a command you
              -- use constantly, so: this line is why.
              inccommand = "split",
            },
          },
        },
      },
    },
  },
}
