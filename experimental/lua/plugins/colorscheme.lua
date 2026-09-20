---@type LazySpec
return {
  "folke/tokyonight.nvim",
  priority = 1000,
  lazy = false,
  ---@type tokyonight.Config
  opts = {
    style = "storm",
    styles = {
      comments = { italic = true },
      keywords = { italic = true },
    },
  },
  config = function(_, opts)
    require("tokyonight").setup(opts)
    vim.cmd.colorscheme "tokyonight"
  end,
}
