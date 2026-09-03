-- Ruff owns all of these.
local unused_off = {
  reportUnusedImport = "none",
  reportUnusedVariable = "none",
  reportUnusedFunction = "none",
  reportUnusedClass = "none",
  reportUnusedExpression = "none",
}

local pyrefly_answers = {
  textDocumentSync = true,
  completionProvider = true,
  positionEncoding = true,
  workspace = true,
}

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
