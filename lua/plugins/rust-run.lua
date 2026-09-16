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
    "AstroNvim/astrocore",
    ---@param opts AstroCoreOpts
    opts = function(_, opts)
      local watch = function() return require "user.languages.rust.watch" end

      opts.commands = opts.commands or {}
      opts.commands.RustWatch = {
        function() watch().toggle() end,
        desc = "Toggle the continuous Cargo build for this workspace",
      }
      opts.commands.RustWatchConfigure = {
        function() watch().configure() end,
        desc = "Set the continuous build's parameters and (re)start it",
      }
      opts.commands.RustWatchStop = {
        function()
          local workspace, err = watch().here()
          if not workspace then
            vim.notify(err or "no Cargo workspace here", vim.log.levels.WARN, { title = "Rust watch" })
          elseif not watch().stop(workspace.root) then
            vim.notify("Nothing is being watched here", vim.log.levels.INFO, { title = "Rust watch" })
          end
        end,
        desc = "Stop this workspace's continuous build",
      }

      local maps = assert(opts.mappings)
      -- Not under `<Leader>r`: every key there makes the action picker sit out
      -- a timeout first, and a toggle should be instant.
      maps.n["<Leader>W"] = {
        function() watch().toggle() end,
        desc = "Toggle continuous Cargo build",
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
