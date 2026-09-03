local query_driver = table.concat({
  vim.fn.expand "~" .. "/.arduino15/packages/esp32/tools/**/bin/*-elf-g*", -- ESP32 (xtensa + riscv32)
  "/usr/bin/*gcc*",
  "/usr/bin/*g++*",
  "/usr/bin/*clang*",
}, ",")

---@type LazySpec
return {
  "AstroNvim/astrolsp",
  ---@type AstroLSPOpts
  opts = {
    ---@diagnostic disable: missing-fields
    config = {
      clangd = {
        cmd = {
          "clangd",
          "--query-driver=" .. query_driver,
          -- Index the whole project in the background, so `grr` (references)
          -- and workspace symbol search see files you have not opened.
          "--background-index",
          -- The lint rules on top of the compiler's own errors -- this is what
          -- produces the "use nullptr instead of NULL" class of hint.
          "--clang-tidy",
          -- Complete `foo` to `foo(bar, baz)` rather than just the name, which
          -- is what makes the signature popup appear right after accepting.
          "--function-arg-placeholders",
          -- Suggest (and insert) the #include a symbol needs.
          "--header-insertion=iwyu",
          "--completion-style=detailed",
          -- ESP32 sketches are one big translation unit each; the default of 4
          -- workers makes the first parse after a `just build` slow.
          "-j=8",
        },
        capabilities = {
          -- clangd counts UTF-8 code units, Neovim defaults to UTF-16.
          -- Mismatched, every diagnostic on a line containing a non-ASCII
          -- character lands in the wrong column.
          offsetEncoding = "utf-8",
        },
      },
    },
  },
}
