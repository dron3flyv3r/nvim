local PROJECT_MARKERS = { "Cargo.toml", "rust-project.json" }

local EDITION = "2024"

---@type overseer.TemplateFileProvider
return {
  name = "user_rust",
  condition = { filetype = { "rust" } },

  ---@param search {dir: string, filetype?: string}
  generator = function(search, cb)
    local file = vim.api.nvim_buf_get_name(0)
    if file == "" then return cb {} end
    if vim.bo.filetype ~= "rust" then return cb {} end
    if vim.fn.executable "rustc" ~= 1 then return cb {} end

    if not vim.tbl_isempty(vim.fs.find(PROJECT_MARKERS, { path = search.dir, upward = true, limit = 1 })) then
      return cb {}
    end

    local bin = vim.fs.joinpath(
      vim.fn.stdpath "cache" --[[@as string]],
      "run-rust",
      vim.fn.sha256(file):sub(1, 16) .. "-" .. vim.fn.fnamemodify(file, ":t:r")
    )

    local name = ("rustc %s"):format(vim.fn.fnamemodify(file, ":t"))

    cb {
      {
        name = name,
        desc = ("compile with edition %s and run, standalone"):format(EDITION),
        tags = { "RUN" },
        builder = function()
          return {
            name = name,
            cmd = {
              "sh",
              "-c",
              -- `-g` because `<Leader>d` breakpoints are useless without it.
              -- No `-O`: a scratch file is compiled far more often than it is
              -- run, so compile time is the thing to spend less of.
              ('mkdir -p "$(dirname "$2")" && rustc --edition %s -g -o "$2" "$1" && exec "$2"'):format(EDITION),
              "sh", -- $0
              file, -- $1
              bin, -- $2
            },
            cwd = vim.fs.dirname(file),
            components = {
              -- The alias from `plugins/tasks.lua` -- this is what opens the
              -- live output pane.
              "default",
              {
                "on_output_quickfix",
                errorformat = require("user.languages.rust.executor").errorformat,
                open_on_match = false,
                items_only = true,
                -- rust-analyzer attaches to a standalone file too (it treats it
                -- as a one-file crate), so its diagnostics are already on
                -- screen and a build's copy would double them.
                set_diagnostics = false,
              },
            },
          }
        end,
      },
    }
  end,
}
