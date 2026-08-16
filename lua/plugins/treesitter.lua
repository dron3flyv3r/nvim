-- Which treesitter parsers get installed.
--
-- WHY THE C/C++ ONES ARE LISTED HERE BY HAND, rather than coming from the
-- language pack: `astrocommunity.pack.cpp` asks for them by setting
-- `treesitter.ensure_installed` on **astrocore**, which is where that option
-- lived in an older AstroNvim. Nothing reads that key any more -- AstroNvim's
-- treesitter spec takes `ensure_installed` on the *plugin* (merged across
-- specs by `opts_extend`), so the pack's list was being written to a table no
-- one looks at. The symptom is quiet: `cpp` files fall back to regex syntax,
-- and the treesitter textobjects (`af` / `if` for a function, `ac` / `ic` for
-- a class) silently do nothing.
--
-- Check what actually got built with `:TSInstallInfo`.

---@type LazySpec
return {
  "nvim-treesitter/nvim-treesitter",
  branch = "main",
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
      -- add more arguments for adding more treesitter parsers
    },
  },
}
