local M = { id = "rust", name = "Rust", priority = 80 }

function M.detect(ctx)
  if ctx.filetype == "rust" then return "rust-analyzer cursor context" end
  if ctx.filetype == "toml" and vim.fs.basename(ctx.file) == "Cargo.toml" then return "Cargo manifest" end
  return false
end

local function command(cmd) return function() vim.cmd(cmd) end end

function M.actions(ctx)
  if ctx.filetype == "toml" then
    local crates = require "crates"
    return {
      { id = "crates.versions", label = "Show published versions", category = "Crates", run = crates.show_versions_popup },
      { id = "crates.features", label = "Show features", category = "Crates", run = crates.show_features_popup },
      { id = "crates.dependencies", label = "Show dependencies", category = "Crates", run = crates.show_dependencies_popup },
      { id = "crates.update", label = "Update crate within version range", category = "Crates", run = crates.update_crate },
      { id = "crates.upgrade", label = "Upgrade crate version range", category = "Crates", run = crates.upgrade_crate },
      { id = "crates.update_all", label = "Update all crates", category = "Crates", run = crates.update_all_crates },
      { id = "crates.upgrade_all", label = "Upgrade all crate ranges", category = "Crates", run = crates.upgrade_all_crates },
      { id = "crates.docs", label = "Open crate documentation", category = "Inspect", run = crates.open_documentation },
      { id = "crates.reload", label = "Reload crate data", category = "Maintenance", run = crates.reload },
    }
  end
  local tasks = require "user.workbench.tasks"
  return {
    { id = "rust.run", label = "Run cursor target", category = "Run", verb = "run", run = command "RustLsp runnables", repeat_action = command "RustLsp! runnables" },
    { id = "rust.test", label = "Test cursor target", category = "Run", verb = "test", run = command "RustLsp testables" },
    { id = "rust.debug", label = "Debug cursor target", category = "Run", verb = "debug", run = command "RustLsp debuggables" },
    { id = "rust.build", label = "Choose Cargo build task", category = "Build", verb = "build", run = tasks.run_picker, repeat_action = tasks.rerun_last },
    { id = "rust.diagnostic", label = "Render full rustc diagnostic", category = "Inspect", run = command "RustLsp renderDiagnostic" },
    { id = "rust.explain", label = "Explain current Rust error", category = "Inspect", run = command "RustLsp explainError" },
    { id = "rust.expand", label = "Expand macro", category = "Inspect", run = command "RustLsp expandMacro" },
    { id = "rust.parent", label = "Go to parent module", category = "Navigate", run = command "RustLsp parentModule" },
    { id = "rust.cargo", label = "Open Cargo.toml", category = "Navigate", run = command "RustLsp openCargo" },
    { id = "rust.docs", label = "Open docs.rs for symbol", category = "Inspect", run = command "RustLsp openDocs" },
    { id = "rust.actions", label = "Grouped Rust code actions", category = "Refactor", run = command "RustLsp codeAction" },
    { id = "rust.move_down", label = "Move item down", category = "Refactor", run = command "RustLsp moveItem down" },
    { id = "rust.move_up", label = "Move item up", category = "Refactor", run = command "RustLsp moveItem up" },
    { id = "rust.proc_macros", label = "Rebuild proc macros", category = "Maintenance", run = command "RustLsp rebuildProcMacros" },
  }
end

return M
