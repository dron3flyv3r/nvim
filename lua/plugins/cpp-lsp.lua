-- C/C++: teaching clangd about cross-compilers.
--
-- THE PROBLEM: clangd works out where the standard headers live by looking at
-- its *own* installation -- so on this machine it assumes host x86_64 glibc.
-- The ESP32 projects are built by an xtensa cross-compiler with a completely
-- different sysroot, so every `#include <...>` that resolves through it failed:
--
--     In included file: 'machine/endian.h' file not found
--
-- ...and one bad include at the top of a translation unit takes every
-- diagnostic below it down with it.
--
-- THE FIX: `--query-driver`. It lets clangd actually *run* the compiler named
-- in `compile_commands.json` with `-v` and read back the include search path it
-- prints. It is opt-in and takes a glob because running arbitrary binaries
-- found in a build file is a thing you should have to ask for by name.
--
-- The glob below covers the Arduino ESP32 toolchains (xtensa for the S3/S2/
-- original, riscv32 for the C3/C6/H2) plus the usual host compilers, so plain
-- CMake projects like `llama.cpp` keep working too.
--
-- The other half of this lives in each project's `.clangd` file, which points
-- at the build directory and strips xtensa-only codegen flags. See
-- `~/code/SOPA-ESP32-MK3/.clangd` for the annotated copy.
--
-- `astrocommunity.pack.cpp` (imported in `community.lua`) supplies the rest:
-- clangd itself, clangd_extensions, cmake-tools and the codelldb debug adapter.
-- It also adds `<Leader>lw` to jump between a .cpp and its .h.

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
