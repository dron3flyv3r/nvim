local debug = require "lang.typescript.debug"
local lsp = require "lang.typescript.lsp"
local project = require "lang.typescript.package"

local TSC_EFM = table.concat({
  "%f(%l\\,%c): %trror TS%n: %m",
  "%f:%l:%c - %trror TS%n: %m",
  "%-G%.%#",
}, ",")
local VITEST_EFM = table.concat({ "%\\s%#❯ %f:%l:%c%.%#", TSC_EFM }, ",")

---@type table<string, string>
local debug_urls = {}

local function restart_servers()
  for _, name in ipairs { "vtsls", "eslint" } do
    if #vim.lsp.get_clients { name = name } > 0 then vim.cmd.LspRestart(name) end
  end
end

local LIFECYCLE = { prepare = true, preinstall = true, install = true, postinstall = true, prepublishOnly = true }

---@param name string
---@return core.ActionCategory, boolean long_running
local function script_category(name)
  if name:match "^test" or name:match "^e2e" then return "Test", false end
  for _, prefix in ipairs { "dev", "start", "serve", "preview", "watch", "storybook" } do
    if vim.startswith(name, prefix) then return "Run", true end
  end
  return "Build", false
end

---@param pkg typescript.Package
---@param name string
---@return boolean
local function is_hook(pkg, name)
  if LIFECYCLE[name] then return true end
  local base = name:match "^pre(.+)$" or name:match "^post(.+)$"
  return base ~= nil and pkg.scripts[base] ~= nil
end

---@param ctx core.Context
---@return typescript.Package|nil
local function package_of(ctx) return project.find(ctx.file ~= "" and ctx.file or ctx.cwd) end

---@param ctx core.Context
---@return integer
local function cursor_row(ctx)
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(win) ~= ctx.bufnr then win = vim.fn.bufwinid(ctx.bufnr) end
  return win ~= -1 and vim.api.nvim_win_get_cursor(win)[1] or 1
end

---@param ctx core.Context
---@return string|nil name, string|nil reason
local function test_at_cursor(ctx)
  local lines = vim.api.nvim_buf_get_lines(ctx.bufnr, 0, cursor_row(ctx), false)
  for i = #lines, 1, -1 do
    local kind, name = lines[i]:match "^%s*(%a+)[%.%w]*%s*%(%s*[\"'`](.-)[\"'`]"
    if kind == "it" or kind == "test" then return name end
  end
  return nil, "The cursor is not inside an it() or test() block"
end

---@param pkg typescript.Package
---@return "vitest"|"jest"|nil, string|nil
local function test_runner(pkg)
  for _, name in ipairs { "vitest", "jest" } do
    local bin = project.bin(pkg, name)
    if bin then return name, bin end
  end
end

---@param text string
---@return string
local function escape_pattern(text) return (text:gsub("[%(%)%.%[%]%*%+%?%^%$%{%}|\\]", "\\%0")) end

---@param pkg typescript.Package
---@param file string
---@param test string|nil
---@return string[]
local function test_cmd(pkg, file, test)
  local runner, bin = test_runner(pkg)
  local cmd = runner == "vitest" and { bin, "run", file } or { bin, file }
  if test then vim.list_extend(cmd, { "-t", escape_pattern(test) }) end
  return cmd
end

---@param pkg typescript.Package
---@param name string
---@return core.Action
local function script_action(pkg, name)
  local category, long_running = script_category(name)
  return {
    id = "script:" .. name,
    label = ("Run the %q script"):format(name),
    category = category,
    run = function()
      require("core.task").run {
        name = ("%s run %s"):format(pkg.manager, name),
        cmd = { pkg.manager, "run", name },
        cwd = pkg.root,
        errorformat = category == "Test" and VITEST_EFM or TSC_EFM,
        queue = not long_running,
      }
    end,
  }
end

---@param ctx core.Context
---@param pkg typescript.Package|nil
---@return string[]|nil cmd, string|nil reason
local function file_runner(ctx, pkg)
  if ctx.file == "" then return nil, "The buffer has no file" end
  if ctx.filetype == "javascript" then return { "node" } end
  if ctx.filetype ~= "typescript" then return nil, "Only plain .js and .ts files run on their own" end
  local tsx = pkg and project.bin(pkg, "tsx")
  if tsx then return { tsx } end
  if project.node_strips_types() then return { "node" } end
  local version = project.node_version()
  return nil, ("Node %s cannot run TypeScript; add tsx as a dev dependency"):format(version and tostring(version) or "")
end

---@param ctx core.Context
---@param opts core.ActionRunOpts
---@param callback fun(argv: string[])
local function with_arguments(ctx, opts, callback)
  local remembered = vim.b[ctx.bufnr].typescript_args
  if opts.repeated and remembered then return callback(vim.split(remembered, "%s+", { trimempty = true })) end
  vim.ui.input({ prompt = "Arguments: ", default = remembered or "" }, function(input)
    if input == nil then return end
    vim.b[ctx.bufnr].typescript_args = input
    callback(vim.split(input, "%s+", { trimempty = true }))
  end)
end

---@param ctx core.Context
---@param pkg typescript.Package|nil
---@param argv string[]
local function run_file(ctx, pkg, argv)
  local runner = assert(file_runner(ctx, pkg))
  require("core.task").run {
    name = ("%s %s"):format(vim.fs.basename(runner[1]), vim.fs.basename(ctx.file)),
    cmd = vim.list_extend(vim.list_extend(runner, { ctx.file }), argv),
    cwd = pkg and pkg.root or ctx.cwd,
    queue = false,
  }
end

---@param ctx core.Context
---@param pkg typescript.Package|nil
---@param argv string[]
local function debug_file(ctx, pkg, argv)
  local runner = assert(file_runner(ctx, pkg))
  require("dap").run {
    type = "pwa-node",
    request = "launch",
    name = vim.fs.basename(ctx.file),
    program = ctx.file,
    args = argv,
    runtimeExecutable = runner[1],
    cwd = pkg and pkg.root or ctx.cwd,
    console = "integratedTerminal",
    sourceMaps = true,
    skipFiles = debug.SKIP_FILES,
  }
end

---@param pkg typescript.Package
---@return string
local function default_url(pkg)
  if pkg.deps.vite then return "http://localhost:5173" end
  return "http://localhost:3000"
end

---@param ctx core.Context
---@return core.Action[]
local function actions(ctx)
  local pkg = package_of(ctx)
  local list = {}

  if pkg then
    local names = vim.tbl_keys(pkg.scripts)
    table.sort(names)
    for _, name in ipairs(names) do
      if not is_hook(pkg, name) then list[#list + 1] = script_action(pkg, name) end
    end

    list[#list + 1] = {
      id = "typecheck",
      label = "Type-check the project",
      category = "Build",
      available = function()
        if not vim.fs.root(ctx.file ~= "" and ctx.file or pkg.root, "tsconfig.json") then
          return "No tsconfig.json above this file"
        end
        return project.bin(pkg, "tsc") ~= nil or "typescript is not installed in node_modules"
      end,
      run = function()
        require("core.task").run {
          name = "tsc --noEmit",
          cmd = { assert(project.bin(pkg, "tsc")), "--noEmit", "--pretty", "false" },
          cwd = vim.fs.root(ctx.file ~= "" and ctx.file or pkg.root, "tsconfig.json"),
          errorformat = TSC_EFM,
        }
      end,
    }

    local function tests_ready()
      if ctx.file == "" then return "The buffer has no file" end
      return test_runner(pkg) ~= nil or "Neither vitest nor jest is installed in node_modules"
    end

    list[#list + 1] = {
      id = "test_file",
      label = "Run the tests in this file",
      category = "Test",
      available = tests_ready,
      run = function()
        require("core.task").run {
          name = (test_runner(pkg)) .. " " .. vim.fs.basename(ctx.file),
          cmd = test_cmd(pkg, ctx.file),
          cwd = pkg.root,
          errorformat = VITEST_EFM,
        }
      end,
    }

    list[#list + 1] = {
      id = "test_cursor",
      label = "Run the test under the cursor",
      category = "Test",
      available = function()
        local ready = tests_ready()
        if ready ~= true then return ready end
        local _, reason = test_at_cursor(ctx)
        return reason or true
      end,
      run = function(_, opts)
        local name = opts.repeated and vim.b[ctx.bufnr].typescript_last_test or assert(test_at_cursor(ctx))
        vim.b[ctx.bufnr].typescript_last_test = name
        require("core.task").run {
          name = ("%s %q"):format(test_runner(pkg), name),
          cmd = test_cmd(pkg, ctx.file, name),
          cwd = pkg.root,
          errorformat = VITEST_EFM,
        }
      end,
    }

    list[#list + 1] = {
      id = "debug_browser",
      label = "Debug the app in a browser",
      category = "Debug",
      available = function()
        local ready = debug.ready()
        if ready ~= true then return ready end
        return debug.browser() ~= nil or "No Chrome, Chromium, Brave or Edge on PATH"
      end,
      run = function(_, opts)
        local function launch(url)
          require("dap").run {
            type = "pwa-chrome",
            request = "launch",
            name = url,
            url = url,
            webRoot = pkg.root,
            runtimeExecutable = debug.browser(),
            sourceMaps = true,
            skipFiles = debug.SKIP_FILES,
          }
        end
        local remembered = debug_urls[pkg.root]
        if opts.repeated and remembered then return launch(remembered) end
        local prompt =
          { prompt = "App URL (the dev server must be running): ", default = remembered or default_url(pkg) }
        vim.ui.input(prompt, function(url)
          if not url or url == "" then return end
          debug_urls[pkg.root] = url
          launch(url)
        end)
      end,
    }

    list[#list + 1] = {
      id = "install",
      label = ("Install dependencies with %s"):format(pkg.manager),
      category = "Maintenance",
      available = vim.fn.executable(pkg.manager) == 1 or (pkg.manager .. " is not on PATH"),
      run = function()
        require("core.task").run {
          name = pkg.manager .. " install",
          cmd = { pkg.manager, "install" },
          cwd = pkg.root,
          on_exit = function(task)
            if task.status == "success" then restart_servers() end
          end,
        }
      end,
    }
  end

  list[#list + 1] = {
    id = "run_file",
    label = "Run this file with Node",
    category = "Run",
    available = function()
      local _, reason = file_runner(ctx, pkg)
      return reason or true
    end,
    run = function() run_file(ctx, pkg, {}) end,
  }

  list[#list + 1] = {
    id = "run_file_args",
    label = "Run this file with Node and arguments",
    category = "Run",
    available = function()
      local _, reason = file_runner(ctx, pkg)
      return reason or true
    end,
    run = function(_, opts)
      with_arguments(ctx, opts, function(argv) run_file(ctx, pkg, argv) end)
    end,
  }

  list[#list + 1] = {
    id = "debug_file",
    label = "Debug this file with Node",
    category = "Debug",
    available = function()
      local ready = debug.ready()
      if ready ~= true then return ready end
      local _, reason = file_runner(ctx, pkg)
      return reason or true
    end,
    run = function() debug_file(ctx, pkg, {}) end,
  }

  list[#list + 1] = {
    id = "debug_attach",
    label = "Attach to a running Node process",
    category = "Debug",
    repeatable = false,
    available = debug.ready,
    run = function()
      require("dap").run {
        type = "pwa-node",
        request = "attach",
        name = "Attach to Node",
        processId = require("dap.utils").pick_process { filter = "node" },
        cwd = pkg and pkg.root or ctx.cwd,
        sourceMaps = true,
        skipFiles = debug.SKIP_FILES,
      }
    end,
  }

  list[#list + 1] = {
    id = "restart_lsp",
    label = "Restart the TypeScript language servers",
    category = "Maintenance",
    repeatable = false,
    available = function()
      return #vim.lsp.get_clients { bufnr = ctx.bufnr } > 0 or "No language server is attached to this buffer"
    end,
    run = restart_servers,
  }

  return list
end

---@type core.ActionProvider
return {
  name = "JS/TS",
  priority = 70,

  detect = function(ctx)
    if not vim.list_contains(lsp.FILETYPES, ctx.filetype) then return false end
    local pkg = package_of(ctx)
    return pkg and ("%s (%s)"):format(pkg.name, pkg.manager) or true
  end,

  actions = actions,

  status = function(ctx)
    local pkg = package_of(ctx)
    local clients = vim.tbl_map(function(c) return c.name end, vim.lsp.get_clients { bufnr = ctx.bufnr })
    local node = project.node_version()
    local lines = {
      ("  node: %s"):format(node and tostring(node) or "not on PATH"),
      ("  servers: %s"):format(#clients > 0 and table.concat(clients, ", ") or "none attached"),
    }
    if pkg then
      local runner = test_runner(pkg)
      table.insert(lines, 1, ("  package: %s at %s"):format(pkg.name, vim.fn.fnamemodify(pkg.root, ":~")))
      lines[#lines + 1] = ("  package manager: %s, dependencies %s"):format(
        pkg.manager,
        project.installed(pkg) and "installed" or "NOT installed"
      )
      lines[#lines + 1] = ("  test runner: %s"):format(runner or "none in node_modules")
    else
      table.insert(lines, 1, "  package: no package.json above this file")
    end
    return lines
  end,
}
