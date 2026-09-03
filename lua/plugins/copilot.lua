return {
  {
    "zbirenbaum/copilot.lua",
    cmd = "Copilot",
    event = "InsertEnter",
    build = ":Copilot auth",
    opts = {
      panel = { enabled = false },
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
  {
    "AstroNvim/astrocore",
    ---@param opts AstroCoreOpts
    opts = function(_, opts)
      local maps = assert(opts.mappings)
      maps.n["<Leader>a"] = { desc = "󱚝 AI" }
      maps.n["<Leader>ac"] = {
        function()
          require("copilot.suggestion").toggle_auto_trigger()
          local enabled = vim.b.copilot_suggestion_auto_trigger
          vim.notify(
            "Copilot suggestions " .. (enabled and "enabled" or "disabled") .. " (this buffer)",
            vim.log.levels.INFO,
            { title = "Copilot" }
          )
        end,
        desc = "Toggle Copilot suggestions (buffer)",
      }
      maps.n["<Leader>aC"] = {
        function()
          require("copilot.command").toggle()
          vim.schedule(function()
            local disabled = require("copilot.client").is_disabled()
            vim.notify(
              "Copilot " .. (disabled and "disabled" or "enabled") .. " (global)",
              vim.log.levels.INFO,
              { title = "Copilot" }
            )
          end)
        end,
        desc = "Toggle Copilot entirely (global)",
      }
      maps.n["<Leader>as"] = { "<Cmd>Copilot status<CR>", desc = "Copilot status" }
    end,
  },
}
