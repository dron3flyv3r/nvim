-- `<Leader>C` -- CMake: configure, build, run, debug.
--
-- WHY THIS EXISTS AND `<Leader>rr` IS NOT ENOUGH: overseer reads a project and
-- turns its tasks into a picker, and for a justfile, a Makefile or npm that is
-- the whole story. It has **no CMake template** -- look in
-- `overseer/template/` and there is `just.lua`, `make.lua`, `cargo.lua` and no
-- `cmake.lua`. So in a plain CMake project `<Leader>rr` offers the shell
-- command entry and nothing else.
--
-- More to the point, "build this CMake project" is not one command. It is a
-- configure step, a build type (Debug / Release), a *build* target and a
-- separate *launch* target, and the second and later builds must reuse the
-- choices from the first. That is state, and cmake-tools is the thing that
-- keeps it (in `.cache/cmake-tools`, per project).
--
-- HOW IT JOINS UP WITH THE REST OF THIS CONFIG: `cmake_executor` and
-- `cmake_runner` below are set to `overseer`, so a CMake build is not a
-- special window with its own rules -- it is an overseer task like any other.
-- It shows up in `<Leader>rt`, it streams into the bottom output pane
-- (`user_output_pane`, see `tasks.lua`), `<Leader>rl` re-runs it, `<Leader>rk`
-- kills it. Press `<Leader>Cb` once to pick the target; after that the edit /
-- build / fix loop is `<Leader>rl` and `æq` / `øq` through the errors.
--
-- The clangd half of C++ lives in `cpp-lsp.lua`; the servers, debug adapter and
-- `<Leader>lw` (source <-> header) come from `astrocommunity.pack.cpp`.

--- Wrap a command so it says what is wrong instead of throwing.
---
--- The `*CurrentFile` commands read the CMake file API reply, which only
--- exists once the project has been configured. Before that -- and in the
--- ESP32 sketches, which are C++ but have no CMakeLists at all -- they index a
--- nil and the traceback is the only feedback you get. These mappings are on
--- every C-family buffer, so that is a reachable state, not a theoretical one.
---@param command string
---@return function
local function in_project(command)
  return function()
    if vim.tbl_isempty(vim.fs.find("CMakeLists.txt", { path = vim.fn.expand "%:p:h", upward = true, limit = 1 })) then
      vim.notify("Not a CMake project -- <Leader>rr for this project's own tasks", vim.log.levels.WARN, {
        title = "CMake",
      })
      return
    end
    vim.cmd(command)
  end
end

--- The `<Leader>C` keys, set on the buffer rather than globally.
---
--- Globally they would be dead weight in every Python and Lua buffer, and
--- which-key would offer a CMake menu while you are editing a notebook.
--- `astrocommunity.pack.cpp` puts `<Leader>lw` on the buffer for the same
--- reason; this follows it.
---
--- The filetype is as far as the filtering goes -- the keys are on every
--- C-family buffer, including the ESP32 sketches that have no CMakeLists.
--- Narrowing it to "buffers in a CMake project" would mean a filesystem walk
--- on every C file opened, to save a menu entry; the commands that misbehave
--- outside a project are wrapped in `in_project` instead.
---@param bufnr integer
local function set_mappings(bufnr)
  require("astrocore").set_mappings({
    n = {
      -- `Package` (󰏖) is the closest thing to a "build" icon in AstroUI's set.
      -- `get_icon` returns "" for a name it does not have, so a wrong guess
      -- here is silent -- see `<Leader>r` in `tasks.lua`, which asks for an
      -- "Overseer" icon that does not exist and gets no icon at all.
      ["<Leader>C"] = { desc = require("astroui").get_icon("Package", 1, true) .. "CMake" },

      -- The two you press. Generate is only needed by hand after editing
      -- CMakeLists in a way that changes the build graph -- `cmake_regenerate_on_save`
      -- below catches the ordinary case.
      ["<Leader>Cb"] = { "<Cmd>CMakeBuild<CR>", desc = "Build" },
      ["<Leader>Cg"] = { "<Cmd>CMakeGenerate<CR>", desc = "Configure (cmake generate)" },

      -- Run and debug the *launch* target, which is a separate choice from the
      -- build target: you build `all` and run one executable out of it.
      ["<Leader>Cr"] = { "<Cmd>CMakeRun<CR>", desc = "Run launch target" },
      ["<Leader>Cd"] = { "<Cmd>CMakeDebug<CR>", desc = "Debug launch target (codelldb)" },

      -- Picking what the four keys above act on.
      ["<Leader>Ct"] = { "<Cmd>CMakeSelectBuildTarget<CR>", desc = "Select build target" },
      ["<Leader>Cl"] = { "<Cmd>CMakeSelectLaunchTarget<CR>", desc = "Select launch target" },
      ["<Leader>Cv"] = { "<Cmd>CMakeSelectBuildType<CR>", desc = "Select build type (Debug/Release)" },
      ["<Leader>Ck"] = { "<Cmd>CMakeSelectKit<CR>", desc = "Select kit (compiler)" },

      -- The command-line arguments the launch target is run and debugged with.
      -- They are remembered per target, so this is a set-once-per-session key.
      ["<Leader>Ca"] = { "<Cmd>CMakeLaunchArgs<CR>", desc = "Set launch arguments" },

      ["<Leader>CT"] = { "<Cmd>CMakeRunTest<CR>", desc = "Run tests (ctest)" },

      -- "Run whatever *this* file is part of" -- cmake-tools looks the buffer
      -- up in the target sources and runs the executable it belongs to, with
      -- no picker. `<Leader>Cr` is the one to press while iterating on one
      -- binary; this is the one for a repo with a dozen of them, where the
      -- answer changes every time you switch file.
      --
      -- NOT a standalone compile of the file, despite the name. Outside a
      -- configured CMake project these throw a Lua traceback from inside
      -- cmake-tools (`attempt to index field 'data'`) rather than reporting
      -- anything useful -- hence the guard.
      ["<Leader>Cf"] = { in_project "CMakeRunCurrentFile", desc = "Run the target this file is part of" },
      ["<Leader>CF"] = { in_project "CMakeDebugCurrentFile", desc = "Debug the target this file is part of" },

      ["<Leader>Cc"] = { "<Cmd>CMakeClean<CR>", desc = "Clean build artifacts" },

      -- There is no `CMakeStop`. Builds and program runs are two different
      -- jobs to cmake-tools -- the executor and the runner -- with a stop
      -- command each, and which one is live depends on whether you last
      -- pressed `<Leader>Cb` or `<Leader>Cr`. Stop both; stopping the idle one
      -- is a no-op. (`<Leader>rk` also works, since these are overseer tasks.)
      ["<Leader>Cx"] = {
        "<Cmd>CMakeStopExecutor<CR><Cmd>CMakeStopRunner<CR>",
        desc = "Stop the running CMake task",
      },

      -- What is currently selected, and where the build directory is. Worth a
      -- key because every command above silently depends on it.
      ["<Leader>Ci"] = { "<Cmd>CMakeSettings<CR>", desc = "Show CMake settings" },
    },
  }, { buffer = bufnr })
end

--- `new_task_opts` for both the executor and the runner.
---
--- Overseer's `default` component alias (extended in `tasks.lua` to open the
--- output pane) plus quickfix parsing. The parsing is the point: without it a
--- failed build is 200 lines of terminal you read with your eyes, and with it
--- the errors are a list you step through with `æq` / `øq` (`]q` / `[q`).
---
--- `open = false` because the output pane already appears; the quickfix window
--- opening on top of it would take a third of the screen for the same text.
--- `<Leader>xq` opens the list when you want it.
local function new_task_opts()
  return {
    components = {
      "default",
      -- No `errorformat`: overseer falls back to the buffer's `&errorformat`,
      -- and Neovim's default already parses gcc and clang's
      -- `file:line:col: error: ...` -- the form both compilers and clang-tidy
      -- emit.
      -- `items_only` is the difference between a list of errors and a copy of
      -- the build log: without it every line ninja prints becomes a quickfix
      -- entry with no file and no line number, and `æq` walks you through
      -- "[1/2] Building CXX object..." on the way to the actual error.
      { "on_output_quickfix", open = false, set_diagnostics = true, items_only = true },
    },
  }
end

---@type LazySpec
return {
  {
    "Civitasv/cmake-tools.nvim",
    -- `astrocommunity.pack.cpp` loads this on the C-family filetypes. Add
    -- `cmake` so the keys are also there while you are editing the CMakeLists
    -- that defines the targets -- which is exactly when you want to re-run
    -- generate and see whether it took.
    ft = { "c", "cpp", "objc", "objcpp", "cuda", "proto", "cmake" },
    opts = {
      -- Default is `out/${variant:buildType}`. `build/` is the directory every
      -- CMake README, `.gitignore` template and CI script already assumes, and
      -- keeping the build type in the path means switching Debug -> Release is
      -- not a full rebuild -- the other one is still sitting there configured.
      cmake_build_directory = "build/${variant:buildType}",

      cmake_generate_options = {
        -- The file clangd reads to learn how each translation unit is
        -- compiled: which `-I`, which `-std`, which `-D`. Without it clangd
        -- guesses, and every project-relative `#include` is red.
        "-DCMAKE_EXPORT_COMPILE_COMMANDS=1",
        -- Ninja over make: it is installed (`/usr/bin/ninja`), it parallelises
        -- to core count without being told, and its dependency scanning is
        -- what makes a one-header-changed rebuild take a second.
        "-G",
        "Ninja",
      },

      cmake_compile_commands_options = {
        -- ...and this is what puts `compile_commands.json` where clangd will
        -- actually look. clangd searches the file's directory and its parents,
        -- plus `build/` -- NOT `build/Debug/`, which is where CMake wrote it.
        -- A soft link at the project root closes that gap, so no `.clangd`
        -- file is needed for ordinary CMake projects. (The ESP32 ones still
        -- need theirs; arduino-cli's database lands somewhere else again. See
        -- `cpp-lsp.lua`.)
        action = "soft_link",
        target = vim.uv.cwd,
      },

      -- Re-run generate when CMakeLists.txt is saved, so adding a source file
      -- or a target does not need `<Leader>Cg` before the next build.
      cmake_regenerate_on_save = true,

      -- Builds and runs both go through overseer -- see the header comment.
      -- The shapes are identical, but they are two separate options and
      -- cmake-tools does not fall back from one to the other.
      cmake_executor = {
        name = "overseer",
        opts = {
          new_task_opts = new_task_opts(),
          -- cmake-tools' own default here opens the overseer task *list* on
          -- the right on every build. `user_output_pane` already opens the
          -- output, which is the half you want to read; the list is
          -- `<Leader>rt` when you want it.
          on_new_task = function() end,
        },
      },
      cmake_runner = {
        name = "overseer",
        opts = {
          new_task_opts = new_task_opts(),
          on_new_task = function() end,
        },
      },

      cmake_dap_configuration = {
        name = "CMake: launch target",
        -- codelldb, installed by `astrocommunity.pack.cpp` via mason-nvim-dap.
        -- gdb is on this machine too, but codelldb is the one with a DAP
        -- interface -- nvim-dap talks to it directly.
        type = "codelldb",
        request = "launch",
        stopOnEntry = false,
        runInTerminal = false,
        -- `false` deliberately: `true` makes codelldb spawn its own terminal
        -- for the program's stdio, which lands outside the dap-ui layout.
        -- With `false`, output goes to the dap-ui console pane, next to the
        -- scopes and breakpoints.
        console = "internalConsole",
      },
    },
    dependencies = {
      {
        "AstroNvim/astrocore",
        ---@param opts AstroCoreOpts
        opts = function(_, opts)
          local autocmds = opts.autocmds or {}
          autocmds.cmake_tools_mappings = {
            {
              event = "FileType",
              pattern = { "c", "cpp", "objc", "objcpp", "cuda", "proto", "cmake" },
              desc = "Add the <Leader>C CMake mappings to C-family buffers",
              callback = function(args) set_mappings(args.buf) end,
            },
          }
          opts.autocmds = autocmds
        end,
      },
    },
  },
}
