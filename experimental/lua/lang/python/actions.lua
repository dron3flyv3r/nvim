local debugpy = require "lang.python.debugpy"
local lsp = require "lang.python.lsp"
local venv = require "lang.python.venv"

local TRACEBACK_EFM = [[  File "%f"\, line %l\, in %m]]
local PYTEST_EFM = table.concat({ TRACEBACK_EFM, "%f:%l: %m", "%-G%.%#" }, ",")
local RUN_EFM = table.concat({ TRACEBACK_EFM, "%-G%.%#" }, ",")
local CHECKER_EFM = table.concat({ "%\\s%#%f:%l:%c - %trror: %m", "%\\s%#%f:%l:%c - %tarning: %m", "%-G%.%#" }, ",")
local RUFF_EFM = "%f:%l:%c: %m,%-G%.%#"

---@param ctx core.Context
---@return string
local function root_of(ctx) return venv.root(ctx.file ~= "" and ctx.file or ctx.cwd) or ctx.cwd end

---@param ctx core.Context
---@param module string
---@return string[]
local function module_cmd(ctx, module)
  local root = root_of(ctx)
  if not venv.for_path(ctx.file) and venv.is_uv_project(root) then return { "uv", "run", "python", "-m", module } end
  return { venv.python(ctx.file), "-m", module }
end

---@param ctx core.Context
---@return boolean|string
local function has_file(ctx)
  if ctx.file == "" or vim.bo[ctx.bufnr].buftype ~= "" then return "The buffer has no file" end
  return true
end

---@param ctx core.Context
---@return boolean|string
local function pytest_ready(ctx)
  if venv.tool(ctx.file, "pytest") or venv.is_uv_project(root_of(ctx)) then return true end
  return "pytest is not installed in the environment (uv add --dev pytest)"
end

---@param bufnr integer
---@param row integer
---@return string|nil indent, string|nil name
local function def_at(bufnr, row)
  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
  local indent, name = line:match "^(%s*)def%s+([%w_]+)"
  if not indent then
    indent, name = line:match "^(%s*)async%s+def%s+([%w_]+)"
  end
  return indent, name
end

---@param ctx core.Context
---@return integer
local function cursor_row(ctx)
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(win) ~= ctx.bufnr then win = vim.fn.bufwinid(ctx.bufnr) end
  return win ~= -1 and vim.api.nvim_win_get_cursor(win)[1] or 1
end

---@param ctx core.Context
---@return string|nil nodeid, string|nil reason
local function test_at_cursor(ctx)
  local row = cursor_row(ctx)
  for i = row, 1, -1 do
    local indent, name = def_at(ctx.bufnr, i)
    if name then
      if not name:match "^test" then return nil, ("%s is not a test function"):format(name) end
      local parts, limit = { name }, #indent
      local lines = vim.api.nvim_buf_get_lines(ctx.bufnr, 0, i - 1, false)
      for j = #lines, 1, -1 do
        if limit == 0 then break end
        local class_indent, class = lines[j]:match "^(%s*)class%s+([%w_]+)"
        if class and #class_indent < limit then
          table.insert(parts, 1, class)
          limit = #class_indent
        end
      end
      return ctx.file .. "::" .. table.concat(parts, "::")
    end
  end
  return nil, "The cursor is not inside a test function"
end

---@param ctx core.Context
---@param opts core.ActionRunOpts
---@return string
local function chosen_test(ctx, opts)
  local remembered = vim.b[ctx.bufnr].python_last_test
  if opts.repeated and remembered then return remembered end
  local nodeid = assert(test_at_cursor(ctx))
  vim.b[ctx.bufnr].python_last_test = nodeid
  return nodeid
end

---@param ctx core.Context
---@param name string
---@param args string[]
---@param efm string
---@param opts? { queue?: boolean }
local function python_task(ctx, name, args, efm, opts)
  require("core.task").run {
    name = name,
    cmd = args,
    cwd = root_of(ctx),
    errorformat = efm,
    queue = opts and opts.queue,
  }
end

---@param ctx core.Context
---@param opts core.ActionRunOpts
---@param callback fun(argv: string[])
local function with_arguments(ctx, opts, callback)
  local remembered = vim.b[ctx.bufnr].python_args
  if opts.repeated and remembered then return callback(vim.split(remembered, "%s+", { trimempty = true })) end
  vim.ui.input({ prompt = "Arguments: ", default = remembered or "" }, function(input)
    if input == nil then return end
    vim.b[ctx.bufnr].python_args = input
    callback(vim.split(input, "%s+", { trimempty = true }))
  end)
end

---@param ctx core.Context
---@param argv string[]
local function run_file(ctx, argv)
  local cmd = vim.list_extend({ venv.python(ctx.file), ctx.file }, argv)
  if not venv.for_path(ctx.file) and venv.is_uv_project(root_of(ctx)) then
    cmd = vim.list_extend({ "uv", "run", "python", ctx.file }, argv)
  end
  python_task(ctx, "python " .. vim.fs.basename(ctx.file), cmd, RUN_EFM, { queue = false })
end

---@param ctx core.Context
---@param config table
local function debug(ctx, config)
  require("dap").run(vim.tbl_extend("keep", config, {
    type = "python",
    request = "launch",
    cwd = root_of(ctx),
    python = { venv.python(ctx.file) },
    console = "integratedTerminal",
    justMyCode = true,
  }))
end

---@param ctx core.Context
---@return boolean|string
local function debuggable(ctx)
  local ready = has_file(ctx)
  if ready ~= true then return ready end
  return debugpy.ready(venv.python(ctx.file))
end

---@param ctx core.Context
---@param on_done fun()
local function after_env_change(ctx, on_done)
  return function(task)
    if task.status ~= "success" then return end
    venv.follow(ctx.file ~= "" and ctx.file or ctx.cwd)
    on_done()
  end
end

local function restart_servers()
  for _, name in ipairs(lsp.names()) do
    if #vim.lsp.get_clients { name = name } > 0 then vim.cmd.LspRestart(name) end
  end
end

---@param ctx core.Context
---@return core.Action[]
local function actions(ctx)
  local checker = lsp.checker()
  return {
    {
      id = "run_file",
      label = "Run this file",
      category = "Run",
      available = has_file,
      run = function() run_file(ctx, {}) end,
    },
    {
      id = "run_file_args",
      label = "Run this file with arguments",
      category = "Run",
      available = has_file,
      run = function(_, opts)
        with_arguments(ctx, opts, function(argv) run_file(ctx, argv) end)
      end,
    },
    {
      id = "test_all",
      label = "Run the tests",
      category = "Test",
      available = pytest_ready,
      run = function() python_task(ctx, "pytest", module_cmd(ctx, "pytest"), PYTEST_EFM) end,
    },
    {
      id = "test_file",
      label = "Run the tests in this file",
      category = "Test",
      available = pytest_ready,
      run = function()
        local cmd = vim.list_extend(module_cmd(ctx, "pytest"), { ctx.file })
        python_task(ctx, "pytest " .. vim.fs.basename(ctx.file), cmd, PYTEST_EFM)
      end,
    },
    {
      id = "test_cursor",
      label = "Run the test under the cursor",
      category = "Test",
      available = function()
        local ready = pytest_ready(ctx)
        if ready ~= true then return ready end
        local _, reason = test_at_cursor(ctx)
        return reason or true
      end,
      run = function(_, opts)
        local nodeid = chosen_test(ctx, opts)
        local cmd = vim.list_extend(module_cmd(ctx, "pytest"), { nodeid })
        python_task(ctx, "pytest " .. nodeid:match "::(.*)$", cmd, PYTEST_EFM)
      end,
    },
    {
      id = "test_failed",
      label = "Rerun the tests that failed last time",
      category = "Test",
      available = pytest_ready,
      run = function()
        local cmd = vim.list_extend(module_cmd(ctx, "pytest"), { "--last-failed" })
        python_task(ctx, "pytest --last-failed", cmd, PYTEST_EFM)
      end,
    },
    {
      id = "debug_file",
      label = "Debug this file",
      category = "Debug",
      available = debuggable,
      run = function() debug(ctx, { name = vim.fs.basename(ctx.file), program = ctx.file }) end,
    },
    {
      id = "debug_file_args",
      label = "Debug this file with arguments",
      category = "Debug",
      available = debuggable,
      run = function(_, opts)
        with_arguments(
          ctx,
          opts,
          function(argv) debug(ctx, { name = vim.fs.basename(ctx.file), program = ctx.file, args = argv }) end
        )
      end,
    },
    {
      id = "debug_test",
      label = "Debug the test under the cursor",
      category = "Debug",
      available = function()
        local ready = debuggable(ctx)
        if ready ~= true then return ready end
        local _, reason = test_at_cursor(ctx)
        return reason or true
      end,
      run = function(_, opts)
        local nodeid = chosen_test(ctx, opts)
        debug(ctx, { name = nodeid:match "::(.*)$", module = "pytest", args = { nodeid } })
      end,
    },
    {
      id = "typecheck",
      label = "Type-check the project",
      category = "Build",
      available = checker ~= nil or "Neither basedpyright nor pyright is installed",
      run = function()
        local cmd = { checker, "--pythonpath", venv.python(ctx.file) }
        python_task(ctx, checker, cmd, CHECKER_EFM)
      end,
    },
    {
      id = "lint",
      label = "Lint the project with ruff",
      category = "Build",
      available = function() return venv.tool(ctx.file, "ruff") ~= nil or "ruff is not installed" end,
      run = function()
        local ruff = assert(venv.tool(ctx.file, "ruff"))
        python_task(ctx, "ruff check", { ruff, "check", "--output-format=concise" }, RUFF_EFM)
      end,
    },
    {
      id = "uv_sync",
      label = "Sync the environment with uv",
      category = "Maintenance",
      available = function()
        return venv.is_uv_project(root_of(ctx)) or "Not a uv project (no pyproject.toml, or no uv)"
      end,
      run = function()
        require("core.task").run {
          name = "uv sync",
          cmd = { "uv", "sync" },
          cwd = root_of(ctx),
          on_exit = after_env_change(ctx, restart_servers),
        }
      end,
    },
    {
      id = "uv_venv",
      label = "Create a .venv with uv",
      category = "Maintenance",
      available = function()
        if vim.fn.executable "uv" ~= 1 then return "uv is not on PATH" end
        return not venv.find(root_of(ctx)) or "This project already has a .venv"
      end,
      run = function()
        require("core.task").run {
          name = "uv venv",
          cmd = { "uv", "venv" },
          cwd = root_of(ctx),
          on_exit = after_env_change(ctx, restart_servers),
        }
      end,
    },
    {
      id = "restart_lsp",
      label = "Restart the Python language servers",
      category = "Maintenance",
      repeatable = false,
      available = function()
        return #vim.lsp.get_clients { bufnr = ctx.bufnr } > 0 or "No language server is attached to this buffer"
      end,
      run = restart_servers,
    },
  }
end

---@type core.ActionProvider
return {
  name = "Python",
  priority = 70,

  detect = function(ctx)
    if ctx.filetype ~= "python" then return false end
    local env = venv.for_path(ctx.file)
    return env and ("%s (%s)"):format(vim.fn.fnamemodify(root_of(ctx), ":~"), vim.fs.basename(env)) or true
  end,

  actions = actions,

  status = function(ctx)
    local env = venv.for_path(ctx.file)
    local inherited = venv.inherited()
    local clients = vim.tbl_map(function(c) return c.name end, vim.lsp.get_clients { bufnr = ctx.bufnr })
    return {
      ("  project: %s%s"):format(
        vim.fn.fnamemodify(root_of(ctx), ":~"),
        venv.is_uv_project(root_of(ctx)) and " (uv)" or ""
      ),
      ("  environment: %s%s"):format(
        env and vim.fn.fnamemodify(env, ":~") or "none -- system interpreter",
        inherited and " (inherited from the shell, not followed)" or ""
      ),
      ("  interpreter: %s"):format(venv.python(ctx.file)),
      ("  servers: %s"):format(#clients > 0 and table.concat(clients, ", ") or "none attached"),
    }
  end,
}
