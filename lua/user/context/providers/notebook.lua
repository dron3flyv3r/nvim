local M = { id = "notebook", name = "Notebook", priority = 100 }

local function has_cells(ctx)
  if ctx.file:match "%.ipynb$" then return true end
  if ctx.filetype ~= "python" then return false end
  local lines = vim.api.nvim_buf_get_lines(ctx.bufnr, 0, math.min(vim.api.nvim_buf_line_count(ctx.bufnr), 300), false)
  return table.concat(lines, "\n"):find("# %%", 1, true) ~= nil
end

function M.detect(ctx) return has_cells(ctx) and "cell under cursor" end

local function command(cmd) return function() vim.cmd(cmd) end end
local function nb(fn, arg) return function() require("user.integrations.notebook")[fn](arg) end end

function M.actions()
  return {
    { id = "notebook.run_cell", label = "Run current cell", category = "Run", verb = "run", priority = 110, run = nb("run_cell", false), repeat_action = command "MoltenReevaluateCell" },
    { id = "notebook.run_next", label = "Run cell and move to next", category = "Run", run = nb("run_cell", true) },
    { id = "notebook.run_line", label = "Run current line", category = "Run", run = nb("run", "line") },
    { id = "notebook.run_all", label = "Run all cells", category = "Run", run = nb "run_all" },
    { id = "notebook.insert_below", label = "Insert cell below", category = "Notebook", run = nb("insert_cell", true) },
    { id = "notebook.insert_above", label = "Insert cell above", category = "Notebook", run = nb("insert_cell", false) },
    { id = "notebook.next_cell", label = "Go to next cell", category = "Navigate", run = nb("goto_cell", 1) },
    { id = "notebook.previous_cell", label = "Go to previous cell", category = "Navigate", run = nb("goto_cell", -1) },
    { id = "notebook.output", label = "Show current cell output", category = "Output", verb = "output", priority = 110, run = command "MoltenShowOutput" },
    { id = "notebook.output_enter", label = "Enter output", category = "Output", run = command "noautocmd MoltenEnterOutput" },
    { id = "notebook.output_hide", label = "Hide output", category = "Output", run = command "MoltenHideOutput" },
    { id = "notebook.output_image", label = "Open output image externally", category = "Output", run = command "MoltenImagePopup" },
    { id = "notebook.output_browser", label = "Open HTML output in browser", category = "Output", run = command "MoltenOpenInBrowser" },
    { id = "notebook.output_delete", label = "Delete current cell output", category = "Output", run = command "MoltenDelete" },
    { id = "notebook.kernel_start", label = "Start/select kernel", category = "Kernel", run = command "MoltenInit" },
    { id = "notebook.kernel_register", label = "Register project environment as kernel", category = "Kernel", run = nb "register_kernel" },
    { id = "notebook.kernel_interrupt", label = "Interrupt kernel", category = "Kernel", verb = "stop", priority = 110, run = command "MoltenInterrupt" },
    { id = "notebook.kernel_restart", label = "Restart kernel and clear output", category = "Kernel", run = command "MoltenRestart!" },
    { id = "notebook.kernel_stop", label = "Shut down kernel", category = "Kernel", run = command "MoltenDeinit" },
    { id = "notebook.import", label = "Import saved notebook outputs", category = "Notebook", run = command "MoltenImportOutput" },
    { id = "notebook.export", label = "Export outputs to notebook", category = "Notebook", run = command "MoltenExportOutput!" },
    { id = "notebook.health", label = "Check notebook setup", category = "Status", run = command "NotebookHealth" },
  }
end

return M
