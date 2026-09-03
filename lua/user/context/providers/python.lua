local M = { id = "python", name = "Python", priority = 60 }

function M.detect(ctx) return ctx.filetype == "python" and "current module" end

local function run_current()
  local target = require("user.languages.python.target").resolve()
  if not target or not target.module then error "Current file is outside a Python project root" end
  require("overseer").run_task {
    name = require("user.languages.python.target").module_template_name(target),
    first = true,
  }
end

function M.actions()
  return {
    { id = "python.run", label = "Run current Python module", category = "Run", run = run_current },
    {
      id = "python.env",
      label = "Refresh Python environment",
      category = "Maintenance",
      run = function() require("user.languages.python.environment").refresh() end,
    },
    {
      id = "python.venv",
      label = "Select virtual environment",
      category = "Project",
      run = function() vim.cmd "VenvSelect" end,
    },
  }
end

return M
