---@type LazySpec
return {
  {
    "CopilotC-Nvim/CopilotChat.nvim",
    dependencies = { "nvim-lua/plenary.nvim" },
    cmd = {
      "CopilotChat",
      "CopilotChatOpen",
      "CopilotChatClose",
      "CopilotChatToggle",
      "CopilotChatStop",
      "CopilotChatReset",
      "CopilotChatModels",
    },
    opts = {
      tools = {},
      resources = {},
      trusted_tools = nil,
      instruction_files = {},
      model = "auto",
      auto_insert_mode = false,
      window = {
        layout = "float",
        width = 0.82,
        height = 0.78,
        border = "rounded",
        title = " Code explanation ",
        zindex = 100,
      },
    },
  },
  {
    "AstroNvim/astrocore",
    ---@param opts AstroCoreOpts
    opts = function(_, opts)
      local maps = assert(opts.mappings)
      maps.n["<Leader>ae"] = {
        function() require("user.ai_explain").ask("quick", "normal") end,
        desc = "Explain code",
      }
      maps.n["<Leader>aE"] = {
        function() require("user.ai_explain").ask("deep", "normal") end,
        desc = "Teach code in depth",
      }
      maps.n["<Leader>at"] = {
        function() require("user.ai_explain").open_chat() end,
        desc = "Discuss last explanation",
      }
      maps.x = maps.x or {}
      maps.x["<Leader>ae"] = {
        function() require("user.ai_explain").ask("quick", "visual") end,
        desc = "Explain selection",
      }
      maps.x["<Leader>aE"] = {
        function() require("user.ai_explain").ask("deep", "visual") end,
        desc = "Teach selection in depth",
      }
    end,
  },
}
