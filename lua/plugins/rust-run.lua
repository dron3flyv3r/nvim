-- Rust execution remains native to rustaceanvim, but every process is handed
-- to Overseer so output and quickfix behave like every other project task.
---@type LazySpec
return {
  {
    "mrcjkb/rustaceanvim",
    optional = true,
    opts = function(_, opts)
      local executor = require("user.languages.rust.executor").executor
      opts.tools = opts.tools or {}
      opts.tools.executor = executor
      opts.tools.test_executor = executor
      opts.tools.crate_test_executor = executor
      return opts
    end,
  },
  {
    "AstroNvim/astrolsp",
    opts = function(_, opts)
      local maps = assert(opts.mappings)
      local function rust(client) return client.name == "rust-analyzer" end
      maps.n.K = {
        "<Cmd>RustLsp hover actions<CR>",
        desc = "Hover (with actions)",
        cond = rust,
      }
      return opts
    end,
  },
  {
    "stevearc/overseer.nvim",
    optional = true,
    opts = function(_, opts)
      require("overseer").add_template_hook(
        { module = "^cargo$" },
        function(task, util)
          util.add_component(task, {
            "on_output_quickfix",
            errorformat = require("user.languages.rust.executor").errorformat,
            open = false,
            open_on_match = false,
            items_only = true,
            set_diagnostics = false,
          })
        end
      )
      return opts
    end,
  },
}
