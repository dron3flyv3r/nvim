local cargo = require "lang.rust.cargo"

local function rustlsp(sub)
  return function() vim.cmd("RustLsp " .. sub) end
end

--- Passed as a function so availability is re-checked when the menu opens
--- rather than captured while it is being built.
---@param ctx core.Context
---@return boolean|string
local function rust_analyzer_ready(ctx)
  if vim.fn.exists ":RustLsp" ~= 2 then return "rustaceanvim has not loaded" end
  if #vim.lsp.get_clients { bufnr = ctx.bufnr, name = "rust-analyzer" } == 0 then
    return "rust-analyzer has not attached to this buffer"
  end
  return true
end

---@return boolean|string
local function codelldb_ready()
  local adapters = require "plugins.debug.adapters"
  return adapters.codelldb() ~= nil or adapters.install_hint()
end

--- rustaceanvim owns the adapter the way it owns the client, but it is the same
--- codelldb the debug layer looks for, so it is the same answer when it is absent.
---@param ctx core.Context
---@return boolean|string
local function debuggable(ctx)
  local ready = rust_analyzer_ready(ctx)
  if ready ~= true then return ready end
  return codelldb_ready()
end

---@param ctx core.Context
---@return rust.CargoWorkspace|nil, string|nil
local function workspace_of(ctx) return cargo.workspace(ctx.file ~= "" and ctx.file or ctx.cwd) end

---@param ctx core.Context
---@param name string
---@param args string[]
local function cargo_task(ctx, name, args)
  local workspace, err = workspace_of(ctx)
  if not workspace then error(err or "no Cargo workspace here") end
  require("core.task").run {
    name = name,
    cmd = vim.list_extend({ "cargo" }, args),
    cwd = workspace.root,
    errorformat = cargo.errorformat,
  }
end

--- rustaceanvim's `debuggables` always launches with an empty argv, so a binary
--- that parses arguments dies inside the parse rather than stopping: clap prints
--- its usage and exits 2, and stepping over that call ends the session. This is
--- the path that can answer a prompt first.
---@param workspace rust.CargoWorkspace
---@param binary string
---@param argv string[]
local function debug_binary(workspace, binary, argv)
  local program = vim.fs.joinpath(workspace.target_dir, "debug", binary)
  require("core.task").run {
    name = ("cargo build --bin %s"):format(binary),
    cmd = { "cargo", "build", "--bin", binary },
    cwd = workspace.root,
    errorformat = cargo.errorformat,
    on_exit = function(task)
      if task.status ~= "success" then return end
      require("dap").run {
        type = "codelldb",
        request = "launch",
        name = ("%s %s"):format(binary, table.concat(argv, " ")),
        program = program,
        args = argv,
        cwd = workspace.root,
        sourceLanguages = { "rust" },
        stopOnEntry = false,
      }
    end,
  }
end

---@param ctx core.Context
---@return boolean|string
local function buildable(ctx)
  if vim.fn.executable "cargo" ~= 1 then return "cargo is not on PATH" end
  local _, err = workspace_of(ctx)
  return err or true
end

local CARGO_TASKS = {
  { id = "build", label = "Build the workspace", category = "Build", args = { "build" } },
  { id = "check", label = "Check the workspace", category = "Build", args = { "check" } },
  { id = "clippy", label = "Lint with clippy", category = "Build", args = { "clippy" } },
  { id = "release", label = "Build in release mode", category = "Build", args = { "build", "--release" } },
  { id = "test_all", label = "Test the workspace", category = "Test", args = { "test" } },
}

---@param ctx core.Context
---@return core.Action[]
local function toml_actions(ctx)
  local ok, crates = pcall(require, "crates")
  if not ok then
    return {
      {
        id = "crates_missing",
        label = "Inspect dependencies",
        category = "Inspect",
        available = "crates.nvim is not loaded",
        run = function() end,
      },
    }
  end

  local function entry(id, label, category, fn)
    return { id = id, label = label, category = category, run = fn }
  end

  return {
    entry("versions", "Show published versions", "Inspect", crates.show_versions_popup),
    entry("features", "Show features", "Inspect", crates.show_features_popup),
    entry("dependencies", "Show dependencies", "Inspect", crates.show_dependencies_popup),
    entry("docs", "Open crate documentation", "Inspect", crates.open_documentation),
    entry("update", "Update crate within its version range", "Maintenance", crates.update_crate),
    entry("upgrade", "Upgrade crate version range", "Maintenance", crates.upgrade_crate),
    entry("update_all", "Update all crates", "Maintenance", crates.update_all_crates),
    entry("upgrade_all", "Upgrade all crate ranges", "Maintenance", crates.upgrade_all_crates),
    entry("reload", "Reload crate data", "Maintenance", crates.reload),
    {
      id = "invalidate",
      label = "Forget cached cargo metadata",
      category = "Maintenance",
      repeatable = false,
      run = function()
        cargo.invalidate()
        vim.notify("Cargo metadata cache cleared", vim.log.levels.INFO, { title = "Rust" })
      end,
    },
    {
      id = "build_after_change",
      label = "Build after the dependency change",
      category = "Build",
      available = buildable(ctx),
      run = function()
        cargo.invalidate()
        cargo_task(ctx, "cargo build", { "build" })
      end,
    },
  }
end

---@type core.ActionProvider
return {
  name = "Rust",
  priority = 80,

  detect = function(ctx)
    if ctx.filetype == "rust" then return "rust-analyzer cursor context" end
    if ctx.filetype == "toml" and vim.fs.basename(ctx.file) == "Cargo.toml" then return "Cargo manifest" end
    return false
  end,

  actions = function(ctx)
    if ctx.filetype == "toml" then return toml_actions(ctx) end

    local buildable_here = buildable(ctx)
    local actions = {}

    for _, task in ipairs(CARGO_TASKS) do
      actions[#actions + 1] = {
        id = task.id,
        label = task.label,
        category = task.category,
        available = buildable_here,
        run = function() cargo_task(ctx, "cargo " .. task.args[1], task.args) end,
      }
    end

    actions[#actions + 1] = {
      id = "run_binary",
      label = "Run a binary target",
      category = "Run",
      available = buildable_here,
      repeatable = false,
      run = function()
        local workspace = assert(workspace_of(ctx))
        local binaries = cargo.binaries(workspace)
        if #binaries == 0 then error "this workspace builds no binaries" end
        if #binaries == 1 then return cargo_task(ctx, "cargo run", { "run", "--bin", binaries[1] }) end
        vim.ui.select(binaries, { prompt = "Run which binary?" }, function(choice)
          if choice then cargo_task(ctx, "cargo run " .. choice, { "run", "--bin", choice }) end
        end)
      end,
    }

    local lsp = {
      { "run_cursor", "Run the target under the cursor", "Run", "runnables" },
      { "test_cursor", "Test the target under the cursor", "Test", "testables" },
      { "code_action", "Grouped Rust code actions", "Refactor", "codeAction" },
      { "move_down", "Move the item down", "Refactor", "moveItem down" },
      { "move_up", "Move the item up", "Refactor", "moveItem up" },
      { "expand", "Expand the macro", "Inspect", "expandMacro" },
      { "explain", "Explain the current error", "Inspect", "explainError" },
      { "diagnostic", "Render the full rustc diagnostic", "Inspect", "renderDiagnostic" },
      { "docs", "Open docs.rs for the symbol", "Inspect", "openDocs" },
      { "parent", "Go to the parent module", "Inspect", "parentModule" },
      { "open_cargo", "Open Cargo.toml", "Inspect", "openCargo" },
      { "proc_macros", "Rebuild proc macros", "Maintenance", "rebuildProcMacros" },
    }
    for _, spec in ipairs(lsp) do
      local id, label, category, sub = spec[1], spec[2], spec[3], spec[4]
      actions[#actions + 1] = {
        id = id,
        label = label,
        category = category,
        available = rust_analyzer_ready,
        run = rustlsp(sub),
      }
    end

    actions[#actions + 1] = {
      id = "debug_args",
      label = "Debug a binary with arguments",
      category = "Debug",
      -- cargo and codelldb only: this path builds and launches itself, so it works
      -- before rust-analyzer has attached.
      available = function(inner)
        local ready = codelldb_ready()
        if ready ~= true then return ready end
        return buildable(inner)
      end,
      run = function(_, opts)
        -- Read on each run, not when the menu was built: <Leader>R re-executes this
        -- closure, and a value captured then predates the run that set it.
        local last_args = vim.b[ctx.bufnr].rust_debug_args
        local last_bin = vim.b[ctx.bufnr].rust_debug_bin
        local workspace = assert(workspace_of(ctx))
        local binaries = cargo.binaries(workspace)
        if #binaries == 0 then error "this workspace builds no binaries" end

        local function launch(binary, input)
          vim.b[ctx.bufnr].rust_debug_args = input
          vim.b[ctx.bufnr].rust_debug_bin = binary
          debug_binary(workspace, binary, vim.split(vim.trim(input), "%s+", { trimempty = true }))
        end

        -- <Leader>R means run it again, not ask again.
        if opts.repeated and last_bin and last_args then return launch(last_bin, last_args) end

        local function ask(binary)
          vim.ui.input({ prompt = ("Arguments for %s: "):format(binary), default = last_args or "" }, function(input)
            if input ~= nil then launch(binary, input) end
          end)
        end

        if #binaries == 1 then return ask(binaries[1]) end
        vim.ui.select(binaries, { prompt = "Debug which binary?" }, function(choice)
          if choice then ask(choice) end
        end)
      end,
    }

    actions[#actions + 1] = {
      id = "debug_cursor",
      label = "Debug the target under the cursor (no arguments)",
      category = "Debug",
      available = debuggable,
      run = rustlsp "debuggables",
    }

    actions[#actions + 1] = {
      id = "debug_last",
      label = "Debug the last target again",
      category = "Debug",
      available = debuggable,
      run = rustlsp "debuggables last",
    }

    actions[#actions + 1] = {
      id = "invalidate",
      label = "Forget cached cargo metadata",
      category = "Maintenance",
      repeatable = false,
      run = function()
        cargo.invalidate()
        vim.notify("Cargo metadata cache cleared", vim.log.levels.INFO, { title = "Rust" })
      end,
    }

    return actions
  end,

  status = function(ctx)
    local workspace, err = workspace_of(ctx)
    if not workspace then return { "  " .. (err or "no workspace") } end
    local names = vim.tbl_map(function(pkg) return pkg.name end, workspace.packages)
    return {
      ("  root: %s"):format(vim.fn.fnamemodify(workspace.root, ":~")),
      ("  packages: %s"):format(table.concat(names, ", ")),
    }
  end,
}
