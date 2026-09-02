-- A focused explanation surface backed by GitHub Copilot Chat.
--
-- `copilot.lua` remains responsible for inline suggestions, while this plugin
-- owns conversations. The user-facing workflow lives in `user.ai_explain`:
-- ask about a line/selection, read the answer in a temporary Markdown popup,
-- then reopen the retained conversation only when follow-up questions matter.
---@type LazySpec
return {
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
    -- Explanation prompts never expose tools, so this surface can answer and
    -- discuss code but cannot modify the workspace or run commands.
    tools = {},
    resources = {},
    trusted_tools = nil,
    instruction_files = {},
    -- This account does not expose the plugin's `gpt-5-mini` default directly;
    -- `auto` lets GitHub select an available Copilot Chat model without a
    -- warning on every explanation.
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
}
