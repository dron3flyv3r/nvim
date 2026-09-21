---@type lang.Module
return {
  ft = { "rust" },

  -- No `lsp` key: rustaceanvim starts and owns the rust-analyzer client
  -- itself, and a second one from vim.lsp.enable would fight it.
  plugins = {
    {
      "mrcjkb/rustaceanvim",
      lazy = false,
      init = function()
        local cargo = require "lang.rust.cargo"
        local executor = {
          execute_command = function(cmd, args, cwd, opts)
            local argv = vim.list_extend({ cmd }, args)
            require("core.task").run {
              name = table.concat(argv, " "),
              cmd = argv,
              cwd = cwd,
              env = opts and opts.env,
              errorformat = cargo.errorformat,
            }
          end,
        }
        -- rustaceanvim derives the launch configuration from cargo's own
        -- metadata, so it owns the adapter here; this only tells it which
        -- codelldb.
        local codelldb = require("plugins.debug.adapters").codelldb()
        vim.g.rustaceanvim = {
          dap = codelldb and { adapter = codelldb } or nil,
          tools = {
            float_win_config = { border = "rounded" },
            executor = executor,
            test_executor = executor,
            crate_test_executor = executor,
          },
          server = {
            default_settings = {
              ["rust-analyzer"] = {
                checkOnSave = true,
                check = { command = "clippy" },
                inlayHints = {
                  maxLength = 25,
                  typeHints = { enable = true },
                  parameterHints = { enable = true },
                  chainingHints = { enable = true },
                  closingBraceHints = { enable = false },
                  lifetimeElisionHints = { enable = "never" },
                },
              },
            },
          },
        }
      end,
    },
    {
      "saecki/crates.nvim",
      event = "BufRead Cargo.toml",
      opts = { completion = { crates = { enabled = true } } },
    },
  },

  actions = require "lang.rust.actions",
}
