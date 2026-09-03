local python = require "user.languages.python.target"

local PYTHON_EFM = table.concat({
  "%-G%.%#<frozen%.%#", -- runpy's own frames -- not your code, not navigable
  '%*[^"]"%f"\\, line %l\\, in %m',
  '%*[^"]"%f"\\, line %l',
  "%-G%.%#",
}, ",")

local COMPONENTS = {
  "default",
  { "on_output_quickfix", errorformat = PYTHON_EFM, open_on_match = false, items_only = true },
}

---@type overseer.TemplateFileProvider
return {
  name = "user_python",
  condition = { filetype = { "python" } },

  generator = function(_, cb)
    local target = python.resolve()
    if not target then return cb {} end

    local pretty_root = vim.fn.fnamemodify(target.root, ":~")
    local tmpls = {}

    if target.module then
      table.insert(tmpls, {
        name = python.module_template_name(target),
        desc = string.format("%s, from %s", target.label, pretty_root),
        tags = { "RUN" },
        builder = function()
          return {
            cmd = vim.list_extend(vim.deepcopy(target.py), { "-m", target.module }),
            -- The project root -- the directory `-m` puts on sys.path.
            cwd = target.root,
            components = COMPONENTS,
          }
        end,
      })
    end

    table.insert(tmpls, {
      name = string.format("python %s", vim.fn.fnamemodify(target.file, ":.")),
      desc = string.format("%s, run the file directly (no package context)", target.label),
      tags = { "RUN" },
      builder = function()
        return {
          cmd = vim.list_extend(vim.deepcopy(target.py), { target.file }),
          cwd = target.root,
          components = COMPONENTS,
        }
      end,
    })

    cb(tmpls)
  end,
}
