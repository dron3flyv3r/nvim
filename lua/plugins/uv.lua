return {
  "benomahony/uv.nvim",
  -- Optional filetype to lazy load when you open a python file
  -- ft = { python }
  -- Optional dependency, but recommended:
  -- dependencies = {
  --   "folke/snacks.nvim"
  -- or
  --   "nvim-telescope/telescope.nvim"
  -- },
  opts = {
    picker_integration = true,
    keymaps = {
      -- uv.nvim defaults to `<Leader>x`, which is AstroNvim's quickfix/
      -- diagnostics prefix -- it was squatting on `<Leader>xq` and friends.
      -- Moved to `<Leader>v` (uV, and it is where the venv commands live).
      prefix = "<Leader>v",
    },
  },
}
