-- Python: one type checker, one linter/formatter, one completion source, with
-- the overlap removed.
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
--   * basedpyright -- types, and completion. "Argument of type X cannot be
--                     assigned to parameter of type Y". Nothing else can do
--                     this.
--   * ruff         -- lint, import hygiene and formatting. F401 unused import,
--                     I001 unsorted imports, UP035 deprecated typing import.
--   * pyrefly      -- completion, and nothing else, and only where
--                     basedpyright came back empty. See below for why.
--
-- WHY A THIRD SERVER FOR COMPLETION: basedpyright returns *zero* completions
-- on a half-typed element inside a bracketed collection. Inside `[...]` Python
-- joins lines implicitly, so this
--
--     transforms.Compose([
--         transforms.Resize((224, 224)),
--         transforms.Ran                     <- typing here
--         transforms.RandomVerticalFlip(),
--     ])
--
-- reaches the server as `transforms.Ran transforms.RandomVerticalFlip()` --
-- two expressions jammed together. basedpyright's parser gives up and answers
-- with an empty list; blink then falls back to its `buffer` source, so you get
-- a menu of words already in the file and none of the ones you were looking
-- for. Typing the trailing comma first fixes it, which is no way to live.
--
-- pyrefly's parser recovers and returns the full member list either way.
--
-- WHY BOTH, RATHER THAN JUST PYREFLY: because they fail in opposite
-- directions, and pyrefly alone loses more than it gains. It cannot see
-- through decorators, and the model builders in torchvision are all decorated:
--
--     @register_model()
--     @handle_legacy_interface(weights=("pretrained", ...))
--     def resnet50(*, weights=..., progress=..., **kwargs) -> ResNet: ...
--
-- basedpyright follows those through and calls `models.resnet50(...)` a
-- `ResNet`, so `net.ev` offers `eval`. pyrefly calls it `Unknown`, and an
-- unknown value has no members -- so `net.` offered nothing at all. ty behaves
-- the same as pyrefly here, so swapping one for the other does not help.
--
-- So basedpyright answers, and pyrefly only fills the silence. The duplicate
-- labels that arrangement would otherwise produce are stripped in
-- `blink.lua` -- see `dedupe_python_lsp` there.
--
-- Ruff also owns *formatting*: `community.lua` deliberately does not import
-- `astrocommunity.pack.python`'s black and isort modules, because with them the
-- save hook ran black, isort and ruff-format over the same buffer.
--
-- Ruff's hover is switched off so `K` always comes from the type checker -- but
-- that is done by `astrocommunity.pack.python.ruff`, not here.
--
-- The unused-symbol rules below are switched off on the checker because Ruff
-- reports the same facts *better*: with a rule code you can look up and a code
-- action that fixes them. The checker only ever greyed them out.
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

-- The only things pyrefly is allowed to answer. Everything else is
-- basedpyright's job, and a second opinion on it is exactly the duplication
-- this file exists to prevent -- two hovers on `K`, two sets of inlay hints,
-- two diagnostics for one mistake.
--
-- `textDocumentSync` is how it hears about your edits at all, so it stays;
-- without it the server would be answering questions about the file as it was
-- when you opened it.
local pyrefly_answers = {
  textDocumentSync = true,
  completionProvider = true,
  positionEncoding = true,
  workspace = true,
}

--- Strip a client back to `pyrefly_answers`.
---
--- Neovim defers wiring up capability handlers with `vim.schedule` precisely so
--- that `on_attach` can delete capabilities first (see `Client:on_attach` in
--- `runtime/lua/vim/lsp/client.lua`), so dropping them here is enough -- inlay
--- hints, semantic tokens and codelens never get attached in the first place.
---@param client vim.lsp.Client
local function completion_only(client)
  for capability in pairs(client.server_capabilities) do
    if not pyrefly_answers[capability] then client.server_capabilities[capability] = nil end
  end
end

---@type LazySpec
return {
  {
    "AstroNvim/astrolsp",
    ---@type AstroLSPOpts
    opts = {
      -- `false` stops a server being set up at all. pyright and basedpyright are
      -- the same tool; running both doubles every type error. mason-lspconfig
      -- enables whatever is installed, so this is what keeps pyright out even if
      -- it is still sitting in the Mason directory.
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

  -- pyrefly has no `nvim-lspconfig` entry, so it is defined here from scratch.
  --
  -- NOT through AstroLSP's `servers` list: that path runs through
  -- `lspconfig.configs`, the pre-0.11 framework, which wants a `root_dir`
  -- function and ignores `root_markers` -- the server is registered, finds no
  -- root, and never starts, with nothing logged. `vim.lsp.enable` is Neovim
  -- 0.11+'s own mechanism and it re-runs `FileType` for buffers that are
  -- already open, so registering this late attaches to the Python file you are
  -- sitting in right now.
  {
    "AstroNvim/astrocore",
    ---@param opts AstroCoreOpts
    opts = function(_, opts)
      local autocmds = opts.autocmds or {}
      autocmds.pyrefly_completion = {
        {
          event = "User",
          pattern = "AstroLspSetup", -- fired once the other servers are set up
          desc = "Register pyrefly as Python's completion-only language server",
          once = true,
          callback = function()
            if vim.fn.executable "pyrefly" ~= 1 then return end
            vim.lsp.config("pyrefly", {
              cmd = { "pyrefly", "lsp" },
              filetypes = { "python" },
              -- It finds `.venv` and resolves third-party imports on its own;
              -- no interpreter path needs passing.
              root_markers = {
                "pyrefly.toml",
                "pyproject.toml",
                "setup.py",
                "setup.cfg",
                "requirements.txt",
                ".git",
              },
              -- What blink advertises it can render. Taken from AstroLSP so
              -- this server is told the same thing as every other one.
              capabilities = require("astrolsp").config.capabilities,
              on_attach = completion_only,
              handlers = {
                -- Belt and braces with `completion_only`: that drops the pull
                -- capability, this drops anything pushed before it ran.
                ["textDocument/publishDiagnostics"] = function() end,
              },
            })
            vim.lsp.enable "pyrefly"
            -- `vim.lsp.enable` re-runs `FileType` for already-open buffers
            -- only once `VimEnter` has fired. Starting Neovim *on* a Python
            -- file gets here first, during startup, so that buffer would be
            -- skipped and sit there with no completion until you touched
            -- another one. Kick it by hand; it is a no-op when there is
            -- nothing to start.
            vim.schedule(function() vim.cmd.doautoall "nvim.lsp.enable FileType" end)
          end,
        },
      }
      opts.autocmds = autocmds
    end,
  },

  {
    "WhoIsSethDaniel/mason-tool-installer.nvim",
    opts = function(_, opts)
      opts.ensure_installed = require("astrocore").list_insert_unique(opts.ensure_installed, { "pyrefly" })
    end,
  },
}
