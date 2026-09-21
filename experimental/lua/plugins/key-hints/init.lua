---@type LazySpec
return {
  "folke/which-key.nvim",
  dependencies = { "nvim-tree/nvim-web-devicons" },
  keys = {
    {
      "<Leader>uH",
      function() require("plugins.key-hints.control").toggle() end,
      desc = "Toggle key hints",
    },
  },
  config = function() require("plugins.key-hints.control").setup() end,
}
