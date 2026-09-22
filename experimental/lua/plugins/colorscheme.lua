---@type LazySpec
return {
  {
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
      require("core.colorscheme").setup "tokyonight"
    end,
  },
  -- lazy.nvim's own `ColorSchemePre` handler loads these when their scheme is
  -- named, and snacks' picker lists an unloaded plugin's `colors/` directory.
  {
    "navarasu/onedark.nvim",
    lazy = true,
    opts = { style = "dark" },
  },
  { "gosukiwi/vim-atom-dark", lazy = true },
}
