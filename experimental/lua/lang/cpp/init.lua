local project = require "lang.cpp.project"

local brace_own_line = {}
for _, ft in ipairs(project.SOURCES) do
  brace_own_line[ft] = true
end

---@type lang.Module
return {
  -- `cmake` and `make` so <Leader>r works from the build files too; clangd
  -- names its own filetypes below and never attaches to them.
  ft = vim.list_extend({ "cmake", "make" }, project.SOURCES),

  -- Absent when the server is not installed: `vim.lsp.enable` on a missing
  -- `cmd` warns at every matching FileType from then on.
  lsp = vim.fn.executable "clangd" == 1 and {
    clangd = {
      cmd = {
        "clangd",
        "--background-index",
        "--clang-tidy",
        "--function-arg-placeholders",
        "--header-insertion=iwyu",
        "--completion-style=detailed",
      },
      filetypes = project.SOURCES,
      root_markers = { ".clangd", "compile_commands.json", "compile_flags.txt", ".git" },
    },
  } or nil,

  plugins = {
    {
      "echasnovski/mini.pairs",
      opts = { brace_own_line = brace_own_line },
    },
  },

  actions = require "lang.cpp.actions",
}
