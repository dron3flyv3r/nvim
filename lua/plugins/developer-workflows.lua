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
      require("user.debug.adapters").setup()
      require("user.debug.ui").setup(opts)
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

      -- AstroNvim's own debug mappings are dropped wholesale rather than partly
      -- overwritten, so the group lists one way to do each thing instead of
      -- three ways to stop a session.
      for _, suffix in ipairs { "C", "h", "O", "p", "q", "Q" } do
        maps.n["<Leader>d" .. suffix] = false
      end

      maps.n["<Leader>d"] = { desc = "Debug" }
      maps.n["<Leader>dd"] = { function() require("user.debug").start() end, desc = "Debug here" }
      maps.n["<Leader>dc"] = { function() require("dap").continue() end, desc = "Continue" }
      maps.n["<Leader>dn"] = { function() require("dap").step_over() end, desc = "Step over" }
      maps.n["<Leader>di"] = { function() require("dap").step_into() end, desc = "Step into" }
      maps.n["<Leader>do"] = { function() require("dap").step_out() end, desc = "Step out" }
      maps.n["<Leader>ds"] = { function() require("dap").run_to_cursor() end, desc = "Run to cursor" }
      maps.n["<Leader>db"] = { function() require("dap").toggle_breakpoint() end, desc = "Toggle breakpoint" }
      maps.n["<Leader>dB"] =
        { function() require("user.debug").conditional_breakpoint() end, desc = "Conditional breakpoint" }
      maps.n["<Leader>dL"] = { function() require("user.debug").logpoint() end, desc = "Logpoint (print, do not stop)" }
      maps.n["<Leader>dl"] = { function() require("user.debug").breakpoints() end, desc = "List breakpoints" }
      maps.n["<Leader>dm"] =
        { function() require("user.debug").mute_breakpoints() end, desc = "Mute / unmute all breakpoints" }
      maps.n["<Leader>dx"] =
        { function() require("user.debug").clear_breakpoints() end, desc = "Delete all breakpoints" }
      maps.n["<Leader>de"] = { function() require("user.debug").exceptions() end, desc = "Exception filters" }
      maps.n["<Leader>dw"] = { function() require("user.debug").watch() end, desc = "Add watch expression" }
      maps.n["<Leader>dE"] = { function() require("user.debug").evaluate() end, desc = "Evaluate expression" }
      maps.n["<Leader>du"] = { function() require("user.debug").toggle_ui() end, desc = "Toggle debug dock" }
      maps.n["<Leader>dR"] = { function() require("dap").repl.toggle() end, desc = "Toggle REPL" }
      maps.n["<Leader>dr"] = { function() require("user.debug").restart() end, desc = "Restart session" }
      -- The only key that ends a session. `dap.terminate()` asks the adapter to
      -- stop and `dap.close()` hangs up; having had one key each meant a session
      -- could be left half stopped with the dock still open.
      maps.n["<Leader>dt"] = { function() require("user.debug").stop() end, desc = "Stop session" }

      maps.v = maps.v or {}
      maps.v["<Leader>d"] = { desc = "Debug" }
      maps.v["<Leader>dE"] = { function() require("dapui").eval() end, desc = "Evaluate selection" }
    end,
  },
}
