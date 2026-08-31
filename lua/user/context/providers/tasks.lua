local M = { id = "tasks", name = "Project tasks", priority = 10 }

function M.detect(ctx)
  local start = ctx.file ~= "" and vim.fs.dirname(ctx.file) or ctx.cwd
  local markers = { "justfile", "Justfile", "Makefile", "makefile", "package.json", ".git" }
  local root = vim.fs.root(start, markers)
  return root and vim.fn.fnamemodify(root, ":~") or "current directory"
end

function M.actions()
  local tasks = require "user.workbench.tasks"
  return {
    { id = "tasks.run", label = "Choose project task", category = "Run", verb = "run", run = tasks.run_picker, repeat_action = tasks.rerun_last },
    { id = "tasks.output", label = "Show last task output", category = "Tasks", verb = "output", run = function() tasks.focus_output(false) end },
    { id = "tasks.output_input", label = "Focus task output for input", category = "Tasks", run = function() tasks.focus_output(true) end },
    { id = "tasks.stop", label = "Stop active task", category = "Tasks", verb = "stop", run = tasks.stop },
    { id = "tasks.stop_all", label = "Stop all running and queued tasks", category = "Maintenance", run = tasks.stop_all },
    { id = "tasks.queue", label = "Queue project task", category = "Tasks", run = tasks.queue },
    { id = "tasks.list", label = "Toggle task list", category = "Tasks", run = function() vim.cmd "OverseerToggle" end },
    { id = "tasks.shell", label = "Run shell command", category = "Run", run = function() vim.cmd "OverseerShell" end },
  }
end

return M
