local roslyn = require "lang.csharp.roslyn"

local ERRORFORMAT = table.concat({
  "%f(%l\\,%c): %trror %m",
  "%f(%l\\,%c): %tarning %m",
  "%f(%l): %trror %m",
  "%f(%l): %tarning %m",
}, ",")

---@param ctx core.Context
---@return string|nil
local function unity_root(ctx)
  local ok, project = pcall(require, "lang.unity.project")
  return ok and project.root(ctx.bufnr) or nil
end

---@param ctx core.Context
---@return string|nil dir
local function target_dir(ctx)
  return vim.fs.root(ctx.bufnr, function(entry) return entry:match "%.slnx?$" ~= nil end)
    or vim.fs.root(ctx.bufnr, function(entry) return entry:match "%.csproj$" ~= nil end)
end

---@param ctx core.Context
---@return boolean|string
local function dotnet_available(ctx)
  if vim.fn.executable "dotnet" ~= 1 then return "dotnet is not on PATH" end
  if unity_root(ctx) then return "Unity owns this build -- compile from the editor instead" end
  return target_dir(ctx) ~= nil or "No .sln or .csproj above this file"
end

---@param ctx core.Context
---@param args string[]
local function dotnet_task(ctx, args)
  local dir = target_dir(ctx)
  if not dir then error "no .sln or .csproj above this file" end
  require("core.task").run {
    name = "dotnet " .. args[1],
    cmd = vim.list_extend({ "dotnet" }, args),
    cwd = dir,
    errorformat = ERRORFORMAT,
  }
end

local DOTNET_TASKS = {
  { id = "build", label = "Build the project", category = "Build", args = { "build" } },
  { id = "rebuild", label = "Rebuild from scratch", category = "Build", args = { "build", "--no-incremental" } },
  { id = "restore", label = "Restore packages", category = "Build", args = { "restore" } },
  { id = "test", label = "Run the tests", category = "Test", args = { "test" } },
  { id = "clean", label = "Clean the build output", category = "Maintenance", args = { "clean" } },
}

---@param ctx core.Context
---@return boolean|string
local function attached(ctx)
  return #vim.lsp.get_clients { bufnr = ctx.bufnr, name = "roslyn_ls" } > 0
    or "roslyn_ls has not attached to this buffer"
end

---@type core.ActionProvider
return {
  name = "C#",
  priority = 70,

  detect = function(ctx)
    if ctx.filetype ~= "cs" then return false end
    local dir = target_dir(ctx)
    return dir and vim.fn.fnamemodify(dir, ":~") or true
  end,

  actions = function(ctx)
    local actions = {}

    for _, task in ipairs(DOTNET_TASKS) do
      actions[#actions + 1] = {
        id = task.id,
        label = task.label,
        category = task.category,
        available = dotnet_available,
        run = function() dotnet_task(ctx, task.args) end,
      }
    end

    actions[#actions + 1] = {
      id = "restart_lsp",
      label = "Restart the C# language server",
      category = "Maintenance",
      repeatable = false,
      available = attached,
      run = function() vim.cmd.LspRestart "roslyn_ls" end,
    }

    actions[#actions + 1] = {
      id = "server_log",
      label = "Open the Roslyn server log directory",
      category = "Inspect",
      repeatable = false,
      available = roslyn.executable() ~= nil or "roslyn-language-server is not installed",
      run = function() vim.ui.open(vim.fs.joinpath(vim.uv.os_tmpdir(), "roslyn_ls/logs")) end,
    }

    actions[#actions + 1] = {
      id = "lsp_log",
      label = "Open the LSP log",
      category = "Inspect",
      repeatable = false,
      run = function() vim.cmd.tabedit(vim.lsp.log.get_filename()) end,
    }

    return actions
  end,

  status = function(ctx)
    local exe = roslyn.executable()
    local dir = target_dir(ctx)
    local client = vim.lsp.get_clients { bufnr = ctx.bufnr, name = "roslyn_ls" }[1]
    return {
      ("  server: %s"):format(exe or "roslyn-language-server not on PATH (set $ROSLYN_LS)"),
      ("  attached: %s"):format(client and (client.config.root_dir or "no root") or "no"),
      ("  build target: %s"):format(dir and vim.fn.fnamemodify(dir, ":~") or "none above this file"),
    }
  end,
}
