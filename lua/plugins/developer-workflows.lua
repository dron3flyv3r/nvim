---@type LazySpec
return {
  {
    "mistweaverco/kulala.nvim",
    ft = { "http", "rest" },
    opts = {
      default_env = "local",
      global_keymaps = false,
      response_format = { indent = 2, expand_tabs = true, sort_keys = false },
      ui = {
        display_mode = "split",
        split_direction = "right",
        default_view = "headers_body",
        max_response_size = 32768,
      },
      lsp = { filetypes = { "http", "rest" }, keymaps = false },
    },
  },
  {
    "rcarriga/nvim-dap-ui",
    dependencies = { "mfussenegger/nvim-dap", "nvim-neotest/nvim-nio" },
    opts = {},
    config = function(_, opts)
      local dap, dapui = require "dap", require "dapui"
      dapui.setup(opts)
      dap.listeners.before.attach.user_dapui = dapui.open
      dap.listeners.before.launch.user_dapui = dapui.open
      dap.listeners.before.event_terminated.user_dapui = function() dapui.close() end
      dap.listeners.before.event_exited.user_dapui = function() dapui.close() end
      -- Those two only fire when the adapter volunteers the event; netcoredbg
      -- closes the connection instead and leaves the panels stranded. These
      -- fire on the requests nvim-dap issues itself, so a stop is a stop.
      dap.listeners.after.terminate.user_dapui = function() dapui.close() end
      dap.listeners.after.disconnect.user_dapui = function() dapui.close() end
    end,
  },
  {
    "AstroNvim/astrocore",
    opts = function(_, opts)
      local maps = assert(opts.mappings)
      opts.commands = opts.commands or {}
      opts.commands.Notes =
        { function() require("user.project_notes").open() end, desc = "Open notes for this project" }
      opts.commands.Note =
        { function() require("user.project_notes").create() end, desc = "Create a project note from this code" }
      maps.n["<Leader>n"] = { desc = "Notes" }
      maps.n["<Leader>nn"] = { function() require("user.project_notes").create() end, desc = "Create project note" }
      maps.n["<Leader>no"] = { function() require("user.project_notes").open() end, desc = "Open project notes" }
      maps.n["<Leader>ns"] = { function() require("user.project_notes").search() end, desc = "Search project notes" }
      maps.x = maps.x or {}
      maps.x["<Leader>nn"] = { function() require("user.project_notes").create() end, desc = "Note selected code" }

      maps.n["<Leader>arv"] = { function() require("user.ai_review").diff() end, desc = "Review uncommitted diff" }
      maps.n["<Leader>arc"] = { function() require("user.ai_review").selection() end, desc = "Review code at cursor" }
      maps.n["<Leader>ari"] =
        { function() require("user.ai_review").investigate() end, desc = "Investigate how this happens" }
      maps.x["<Leader>arc"] = { function() require("user.ai_review").selection() end, desc = "Review selection" }
      maps.x["<Leader>ari"] = { function() require("user.ai_review").investigate() end, desc = "Investigate selection" }

      maps.n["<Leader>d"] = { desc = "Debug" }
      maps.n["<Leader>dc"] = { function() require("dap").continue() end, desc = "Continue / start" }
      maps.n["<Leader>dn"] = { function() require("dap").step_over() end, desc = "Step over" }
      maps.n["<Leader>di"] = { function() require("dap").step_into() end, desc = "Step into" }
      maps.n["<Leader>do"] = { function() require("dap").step_out() end, desc = "Step out" }
      maps.n["<Leader>dr"] = { function() require("user.debug").restart() end, desc = "Restart session" }
      maps.n["<Leader>dt"] = { function() require("user.debug").terminate() end, desc = "Terminate session" }
      maps.n["<Leader>dU"] = { function() require("user.debug").toggle_ui() end, desc = "Toggle debug UI" }
      -- AstroNvim's own stop mappings bypass the listeners above: `dap.close()`
      -- dispatches nothing, so without these the panels survive the session.
      maps.n["<Leader>dq"] = { function() require("user.debug").close() end, desc = "Close session" }
      maps.n["<Leader>dQ"] = { function() require("user.debug").terminate() end, desc = "Terminate session" }
      maps.n["<Leader>du"] = { function() require("dap").run_to_cursor() end, desc = "Run to cursor" }
      maps.n["<Leader>db"] = { function() require("dap").toggle_breakpoint() end, desc = "Toggle breakpoint" }
      maps.n["<Leader>dB"] =
        { function() require("user.debug").conditional_breakpoint() end, desc = "Conditional breakpoint" }
      maps.n["<Leader>dl"] = { function() require("user.debug").breakpoints() end, desc = "List breakpoints" }
      maps.n["<Leader>de"] = { function() require("user.debug").exceptions() end, desc = "Exception breakpoints" }
    end,
  },
}
