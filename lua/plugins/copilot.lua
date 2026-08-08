---@type LazySpec
return {
  -- Core Copilot engine
  {
    "zbirenbaum/copilot.lua",
    cmd = "Copilot",
    event = "InsertEnter",
    build = ":Copilot auth",
    opts = {
      panel = { enabled = false },
      -- enable inline ghost text suggestions; accept with Right arrow
      suggestion = {
        enabled = true,
        auto_trigger = true,
        keymap = {
          accept = false,
          accept_word = false,
          accept_line = "<M-l>",
          next = "<M-]>",
          prev = "<M-[>",
          dismiss = "<C-]>",
        },
      },
      filetypes = {},
    },
  },

  -- Feed Copilot into nvim-cmp popup
  {
    "zbirenbaum/copilot-cmp",
    enabled = false, -- disable Copilot items in cmp menu (we use inline suggestions)
    dependencies = { "zbirenbaum/copilot.lua" },
    opts = {},
    config = function(_, opts) require("copilot_cmp").setup(opts) end,
  },

  -- Add Copilot source to nvim-cmp and free <Tab>
  {
    "hrsh7th/nvim-cmp",
    ---@param opts cmp.ConfigSchema
    opts = function(_, opts)
      local cmp = require "cmp"
      opts.sources = opts.sources or {}
      -- do not add Copilot to cmp sources; Copilot suggestions are inline

      -- keep existing mappings but remove Tab/S-Tab to free Tab key
      opts.mapping = opts.mapping or cmp.mapping.preset.insert {}
      opts.mapping["<Tab>"] = nil
      opts.mapping["<S-Tab>"] = nil
      -- ensure alternative navigation keys exist
      opts.mapping["<C-n>"] = opts.mapping["<C-n>"] or cmp.mapping.select_next_item()
      opts.mapping["<C-p>"] = opts.mapping["<C-p>"] or cmp.mapping.select_prev_item()
      opts.mapping["<CR>"] = opts.mapping["<CR>"] or cmp.mapping.confirm { select = false }

      return opts
    end,
  },
}
