-- rustaceanvim owns rust-analyzer. bacon-ls owns diagnostics when installed;
-- otherwise rust-analyzer runs Clippy on save. See
-- `docs/decisions/rust-diagnostics.md` for the toolchain rationale.
local bacon_owns_diagnostics = vim.fn.executable "bacon-ls" == 1

---@type LazySpec
return {
  {
    "mrcjkb/rustaceanvim",
    optional = true,
    dependencies = { "neovim/nvim-lspconfig" },
    ---@param opts table
    opts = function(_, opts)
      opts.server = opts.server or {}
      opts.server.on_attach = function(client, bufnr) require("astrolsp").on_attach(client, bufnr) end

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
      servers = { "rust_analyzer" },

      ---@diagnostic disable: missing-fields
      config = {
        rust_analyzer = {
          settings = {
            ["rust-analyzer"] = {
              checkOnSave = not bacon_owns_diagnostics,
              diagnostics = { enable = true },

              cargo = {
                extraEnv = { CARGO_PROFILE_RUST_ANALYZER_INHERITS = "dev" },
                extraArgs = { "--profile", "rust-analyzer" },
              },
            },
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
      autocmds.bacon_ls = {
        {
          event = "User",
          pattern = "AstroLspSetup", -- once the other servers are set up
          desc = "Register bacon-ls as Rust's diagnostics source",
          once = true,
          callback = function()
            if not bacon_owns_diagnostics then return end
            vim.lsp.config("bacon_ls", {
              capabilities = require("astrolsp").config.capabilities,
              settings = {
                bacon_ls = {
                  backend = "cargo",
                  cargo = {
                    -- The same tool rust-analyzer would have run, so switching
                    -- who reports errors does not change WHICH errors.
                    command = "clippy",
                    extraArgs = { "--no-deps", "--profile", "rust-analyzer" },
                    env = { CARGO_PROFILE_RUST_ANALYZER_INHERITS = "dev" },
                    checkOnSave = true,
                    updateOnInsertDebounceMillis = 500,
                  },
                },
              },
              init_options = { cargo = { updateOnInsert = true } },
            })
            vim.lsp.enable "bacon_ls"
            vim.schedule(function() vim.cmd.doautoall "nvim.lsp.enable FileType" end)
          end,
        },
      }

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
