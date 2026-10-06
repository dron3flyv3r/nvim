---@type LazySpec
return {
  url = "https://gitlab.com/schrieveslaach/sonarlint.nvim",
  name = "sonarlint.nvim",
  lazy = true,
  keys = {
    {
      "<Leader>si",
      function() require("plugins.code-analysis.control").cached_report() end,
      desc = "SonarQube issues on this PR",
    },
  },
  ---@type plugins.analysis.Opts
  opts = { languages = {} },
  config = function(_, opts) require("plugins.code-analysis.control").setup(opts) end,
}
