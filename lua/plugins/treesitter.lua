---@type LazySpec
return {
  {
    "nvim-treesitter/nvim-treesitter",
    opts = {
      lazy = false,
      ensure_installed = {
        "lua",
        "vim",
        -- C/C++, and the build files that drive them. `cmake` is what gives
        -- CMakeLists.txt highlighting; `make` covers Makefiles.
        "c",
        "cpp",
        "cmake",
        "make",
        "rust",
        "toml",
        "diff",
      },
    },
  },

  {
    "RRethy/vim-illuminate",
    optional = true,
    opts = { providers = { "lsp", "regex" } },
  },
}
