-- CMake owns project configuration and target state; contextual actions expose
-- its commands, while Overseer owns the shared process/output experience.
local function task_options()
  return {
    components = {
      "default",
      { "on_output_quickfix", open = false, set_diagnostics = true, items_only = true },
    },
  }
end

---@type LazySpec
return {
  "Civitasv/cmake-tools.nvim",
  ft = { "c", "cpp", "objc", "objcpp", "cuda", "proto", "cmake" },
  opts = {
    cmake_build_directory = "build/${variant:buildType}",
    cmake_generate_options = { "-DCMAKE_EXPORT_COMPILE_COMMANDS=1", "-G", "Ninja" },
    cmake_compile_commands_options = { action = "soft_link", target = vim.uv.cwd },
    cmake_regenerate_on_save = true,
    cmake_executor = { name = "overseer", opts = { new_task_opts = task_options(), on_new_task = function() end } },
    cmake_runner = { name = "overseer", opts = { new_task_opts = task_options(), on_new_task = function() end } },
    cmake_dap_configuration = {
      name = "CMake: launch target",
      type = "codelldb",
      request = "launch",
      stopOnEntry = false,
      runInTerminal = false,
      console = "internalConsole",
    },
  },
}
