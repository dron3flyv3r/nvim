return {
  {
    "coder/claudecode.nvim",
    dependencies = { "folke/snacks.nvim" },
    cmd = {
      "ClaudeCode",
      "ClaudeCodeFocus",
      "ClaudeCodeSelectModel",
      "ClaudeCodeAdd",
      "ClaudeCodeSend",
      "ClaudeCodeTreeAdd",
      "ClaudeCodeStatus",
      "ClaudeCodeStart",
      "ClaudeCodeStop",
      "ClaudeCodeOpen",
      "ClaudeCodeClose",
      "ClaudeCodeDiffAccept",
      "ClaudeCodeDiffDeny",
      "ClaudeCodeCloseAllDiffs",
    },
    opts = {
      terminal = {
        provider = "snacks",
        split_side = "right",
        split_width_percentage = 0.30,
      },
      diff_opts = {
        layout = "vertical",
        open_in_new_tab = false,
      },
    },
  },
  {
    "AstroNvim/astrocore",
    ---@param opts AstroCoreOpts
    opts = function(_, opts)
      local maps = assert(opts.mappings)
      maps.n["<Leader>aa"] = { "<Cmd>ClaudeCode<CR>", desc = "Toggle Claude" }
      maps.n["<Leader>af"] = { "<Cmd>ClaudeCodeFocus<CR>", desc = "Focus Claude" }
      maps.n["<Leader>ab"] = { "<Cmd>ClaudeCodeAdd %<CR>", desc = "Add this buffer to Claude" }
      maps.n["<Leader>ar"] = { "<Cmd>ClaudeCode --resume<CR>", desc = "Resume a Claude session" }
      maps.n["<Leader>an"] = { "<Cmd>ClaudeCode --continue<CR>", desc = "Continue the last Claude session" }
      maps.n["<Leader>am"] = { "<Cmd>ClaudeCodeSelectModel<CR>", desc = "Select Claude model" }
      maps.n["<Leader>aS"] = { "<Cmd>ClaudeCodeStatus<CR>", desc = "Claude connection status" }
      maps.n["<Leader>ay"] = { "<Cmd>ClaudeCodeDiffAccept<CR>", desc = "Accept Claude's diff" }
      maps.n["<Leader>ad"] = { "<Cmd>ClaudeCodeDiffDeny<CR>", desc = "Reject Claude's diff" }
      maps.x = maps.x or {}
      maps.x["<Leader>as"] = { "<Cmd>ClaudeCodeSend<CR>", desc = "Send selection to Claude" }

      opts.autocmds = opts.autocmds or {}
      opts.autocmds.claude_tree_add = {
        {
          event = "FileType",
          pattern = { "neo-tree", "snacks_picker_list" },
          desc = "Add the file under the cursor to Claude's context",
          callback = function(args)
            vim.keymap.set("n", "<Leader>as", "<Cmd>ClaudeCodeTreeAdd<CR>", {
              buffer = args.buf,
              desc = "Add file to Claude",
            })
          end,
        },
      }
    end,
  },
}
