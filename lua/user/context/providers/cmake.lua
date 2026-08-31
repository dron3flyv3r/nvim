local M = { id = "cmake", name = "CMake", priority = 70 }

function M.detect(ctx)
  if not vim.tbl_contains({ "c", "cpp", "objc", "objcpp", "cuda", "proto", "cmake" }, ctx.filetype) then return false end
  local start = ctx.file ~= "" and vim.fs.dirname(ctx.file) or ctx.cwd
  local root = vim.fs.root(start, { "CMakeLists.txt" })
  return root and vim.fn.fnamemodify(root, ":~") or false
end

local function command(cmd) return function() vim.cmd(cmd) end end

function M.actions()
  return {
    { id = "cmake.run", label = "Run target containing current file", category = "Run", verb = "run", run = command "CMakeRunCurrentFile", repeat_action = require("user.workbench.tasks").rerun_last },
    { id = "cmake.test", label = "Run CTest", category = "Run", verb = "test", run = command "CMakeRunTest" },
    { id = "cmake.debug", label = "Debug target containing current file", category = "Run", verb = "debug", run = command "CMakeDebugCurrentFile" },
    { id = "cmake.build", label = "Build selected target", category = "Build", verb = "build", run = command "CMakeBuild", repeat_action = require("user.workbench.tasks").rerun_last },
    { id = "cmake.configure", label = "Configure/generate project", category = "Build", run = command "CMakeGenerate" },
    { id = "cmake.run_target", label = "Run selected launch target", category = "Run", run = command "CMakeRun" },
    { id = "cmake.debug_target", label = "Debug selected launch target", category = "Run", run = command "CMakeDebug" },
    { id = "cmake.build_target", label = "Select build target", category = "Project", run = command "CMakeSelectBuildTarget" },
    { id = "cmake.launch_target", label = "Select launch target", category = "Project", run = command "CMakeSelectLaunchTarget" },
    { id = "cmake.build_type", label = "Select build type", category = "Project", run = command "CMakeSelectBuildType" },
    { id = "cmake.kit", label = "Select compiler kit", category = "Project", run = command "CMakeSelectKit" },
    { id = "cmake.arguments", label = "Set launch arguments", category = "Project", run = command "CMakeLaunchArgs" },
    { id = "cmake.clean", label = "Clean build artifacts", category = "Maintenance", run = command "CMakeClean" },
    { id = "cmake.stop", label = "Stop CMake execution", category = "Maintenance", verb = "stop", run = command "CMakeStopExecutor | CMakeStopRunner" },
    { id = "cmake.status", label = "Show CMake settings", category = "Status", run = command "CMakeSettings" },
  }
end

return M
