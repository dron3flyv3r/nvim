-- Python: one type checker + one linter, with the overlap removed.
--
-- THE PROBLEM: three servers were fighting over every Python buffer.
-- `pyright` and `basedpyright` are the *same* type checker (basedpyright is a
-- fork of it), so every type error was reported twice; and both of them also
-- duplicated Ruff on unused imports. Hence virtual-text lines that said the
-- same thing twice:
--
--     import torch   ●● Ruff: Import block is un-sorted   ● Pyright: "torch" is not accessed
--
-- THE SPLIT: one server per job.
--
--   * basedpyright -- types. "Argument of type X cannot be assigned to
--                     parameter of type Y". Nothing else can do this.
--                     Chosen over pyright because it is what
--                     `astrocommunity.pack.python` already configures, and it
--                     adds inlay hints and a permissive licence.
--   * ruff         -- lint and import hygiene. F401 unused import, I001
--                     unsorted imports, UP035 deprecated typing import.
--
-- The unused-symbol rules below are switched off on the checker because Ruff
-- reports the same facts *better*: with a rule code you can look up and a code
-- action that fixes them. The checker only ever greyed them out.
--
-- Ruff also answers `textDocument/hover`, which competed with the checker for
-- `K`. Ruff's hover only ever returns the docs for a lint rule, so it is
-- switched off and hover always comes from the type checker.
--
-- NOTE: basedpyright needs a project root to do full type analysis -- a
-- `pyproject.toml`, `setup.py`, `.git` or similar. In a loose directory with no
-- root marker it still resolves imports but silently skips most type checking.
-- If type errors ever seem missing, check the project has one.

-- Ruff owns all of these.
local unused_off = {
  reportUnusedImport = "none",
  reportUnusedVariable = "none",
  reportUnusedFunction = "none",
  reportUnusedClass = "none",
  reportUnusedExpression = "none",
}

---@type LazySpec
return {
  {
    "AstroNvim/astrolsp",
    ---@type AstroLSPOpts
    opts = {
      -- `false` stops a server being set up at all. pyright and basedpyright
      -- are the same tool; running both doubles every type error.
      handlers = { pyright = false },
      ---@diagnostic disable: missing-fields
      config = {
        basedpyright = {
          settings = {
            -- basedpyright reads its own section; `python.analysis` is the
            -- pyright-compatible alias. Set both so neither fork surprises us.
            basedpyright = { analysis = { diagnosticSeverityOverrides = unused_off } },
            python = { analysis = { diagnosticSeverityOverrides = unused_off } },
          },
        },
      },
    },
  },
  {
    "AstroNvim/astrocore",
    ---@type AstroCoreOpts
    opts = {
      autocmds = {
        ruff_defer_hover = {
          {
            event = "LspAttach",
            desc = "Let the type checker own hover; Ruff's only returns lint-rule docs",
            callback = function(args)
              local client = vim.lsp.get_client_by_id(args.data.client_id)
              if client and client.name == "ruff" then client.server_capabilities.hoverProvider = false end
            end,
          },
        },
      },
    },
  },
}
