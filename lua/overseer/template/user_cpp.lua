local PROJECT_MARKERS = {
  "CMakeLists.txt",
  "Makefile",
  "makefile",
  "GNUmakefile",
  "justfile",
  "Justfile",
  ".justfile",
  "meson.build",
  "build.ninja",
  "compile_commands.json",
  ".clangd",
}

local LANGUAGES = {
  cpp = { cc = "g++", std = "-std=c++23" },
  c = { cc = "gcc", std = "-std=c23" },
}

---@type overseer.TemplateFileProvider
return {
  name = "user_cpp",
  condition = { filetype = vim.tbl_keys(LANGUAGES) },

  ---@param search {dir: string, filetype?: string}
  generator = function(search, cb)
    local file = vim.api.nvim_buf_get_name(0)
    if file == "" then return cb {} end
    local lang = LANGUAGES[vim.bo.filetype]
    if not lang then return cb {} end
    if vim.fn.executable(lang.cc) ~= 1 then return cb {} end

    if not vim.tbl_isempty(vim.fs.find(PROJECT_MARKERS, { path = search.dir, upward = true, limit = 1 })) then
      return cb {}
    end

    local bin = vim.fs.joinpath(
      vim.fn.stdpath "cache" --[[@as string]],
      "run-cpp",
      vim.fn.sha256(file):sub(1, 16) .. "-" .. vim.fn.fnamemodify(file, ":t:r")
    )

    local name = ("%s %s"):format(lang.cc, vim.fn.fnamemodify(file, ":t"))

    cb {
      {
        name = name,
        desc = ("compile with %s and run, standalone"):format(lang.std),
        tags = { "RUN" },
        builder = function()
          return {
            -- Without this the task is *named* after its command, and the
            -- command is a 200-character `sh -c` -- which is what the task
            -- list and notifications would show.
            name = name,
            cmd = {
              "sh",
              "-c",
              ('mkdir -p "$(dirname "$2")" && %s %s -g -Wall -Wextra -o "$2" "$1" && exec "$2"'):format(
                lang.cc,
                lang.std
              ),
              "sh", -- $0
              file, -- $1
              bin, -- $2
            },
            cwd = vim.fs.dirname(file),
            components = {
              "default",
              { "on_output_quickfix", open_on_match = false, items_only = true, set_diagnostics = true },
            },
          }
        end,
      },
    }
  end,
}
