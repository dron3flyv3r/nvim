local M = { id = "make", name = "Make", priority = 65 }

local FILETYPES = { "c", "cpp", "objc", "objcpp", "cuda", "make" }
local MAKEFILES = { "GNUmakefile", "makefile", "Makefile" }
local SKIP_DIRS = { [".git"] = true, CMakeFiles = true, node_modules = true }

-- gcc, clang and ld, plus make's directory changes so a recursive make still
-- resolves paths. Everything else is dropped, so `øq` only walks diagnostics.
local ERRORFORMAT = table.concat({
  [[%f:%l:%c: fatal %trror: %m]],
  [[%f:%l:%c: %trror: %m]],
  [[%f:%l:%c: %tarning: %m]],
  [[%f:%l:%c: %tote: %m]],
  [[%f:%l: %trror: %m]],
  [[%f:(%*[^)]): %m]],
  [[%D%*\a[%*\d]: Entering directory %*[`']%f']],
  [[%X%*\a[%*\d]: Leaving directory %*[`']%f']],
  [[%D%*\a: Entering directory %*[`']%f']],
  [[%X%*\a: Leaving directory %*[`']%f']],
  [[%-G%.%#]],
}, ",")

--- Per root, for this session: the last target, executable and arguments, so
--- the prompts open on the previous answer.
---@type table<string, { target?: string, program?: string, args?: string }>
local memory = {}

---@param list string[]
---@param first? string
---@return string[]
local function front(list, first)
  if not first or not vim.tbl_contains(list, first) then return list end
  local rest = vim.tbl_filter(function(item) return item ~= first end, list)
  return { first, unpack(rest) }
end

---@param ctx user.Context
---@return string|nil
local function root_of(ctx)
  local start = ctx.file ~= "" and vim.fs.dirname(ctx.file) or ctx.cwd
  return vim.fs.root(start, MAKEFILES)
end

function M.detect(ctx)
  if not vim.tbl_contains(FILETYPES, ctx.filetype) then return false end
  local root = root_of(ctx)
  return root and vim.fn.fnamemodify(root, ":~") or false
end

---@param root string
---@param args string[]
---@param on_success? fun()
local function make(root, args, on_success)
  local cmd = vim.list_extend({ "make" }, args)
  local task = require("overseer").new_task {
    name = table.concat(cmd, " "),
    cmd = cmd,
    cwd = root,
    components = {
      "default",
      {
        "on_output_quickfix",
        errorformat = ERRORFORMAT,
        open = false,
        open_on_match = false,
        items_only = true,
        set_diagnostics = true,
      },
    },
  }
  if on_success then
    task:subscribe("on_complete", function(_, status)
      -- Inside overseer's dispatch loop; let it unwind before the next step.
      if status == "SUCCESS" then vim.schedule(on_success) end
      return true
    end)
  end
  task:start()
end

--- Parsed from make's own database, so included makefiles count too.
---@param root string
---@return string[]
local function targets(root)
  local result = vim
    .system({ "make", "-npq", "-C", root, ".DEFAULT" }, { text = true, env = { LC_ALL = "C" } })
    :wait(10000)
  local names, seen = {}, {}
  local default
  local in_files, not_target = false, false
  for line in (result.stdout or ""):gmatch "[^\n]*" do
    default = default or line:match "^%.DEFAULT_GOAL :?= (%S+)"
    if line == "# Files" then
      in_files = true
    elseif line:match "^# Finished Make data base" then
      in_files = false
    elseif in_files and line == "# Not a target:" then
      not_target = true
    elseif in_files then
      local name = line:match "^([^%s#:=][^%s:=]*):"
      if name then
        local listed = not name:find "^%." and not name:find("%", 1, true) and not line:match "^[^:]*:="
        if listed and not not_target and not seen[name] then
          seen[name] = true
          names[#names + 1] = name
        end
        not_target = false
      end
    end
  end
  table.sort(names, function(a, b)
    if (a == default) ~= (b == default) then return a == default end
    return a < b
  end)
  return names
end

---@param path string
---@return boolean
local function is_elf(path)
  local fd = io.open(path, "rb")
  if not fd then return false end
  local magic = fd:read(4)
  fd:close()
  return magic == "\127ELF"
end

--- A Makefile does not say what it produces, so this is every ELF executable
--- under the root, newest first.
---@param root string
---@return string[]
local function executables(root)
  local found = {}
  local skip = function(dir) return not SKIP_DIRS[vim.fs.basename(dir)] end
  for name, kind in vim.fs.dir(root, { depth = 3, skip = skip }) do
    local path = vim.fs.joinpath(root, name)
    if kind == "file" and not name:match "%.so[%.%d]*$" and vim.fn.executable(path) == 1 and is_elf(path) then
      local stat = vim.uv.fs_stat(path)
      found[#found + 1] = { path = path, mtime = stat and stat.mtime.sec or 0 }
    end
  end
  table.sort(found, function(a, b) return a.mtime > b.mtime end)
  return vim.tbl_map(function(entry) return entry.path end, found)
end

---@param root string
---@param callback fun(program: string)
local function choose_program(root, callback)
  local function pick()
    local programs = executables(root)
    if #programs == 0 then
      vim.notify("make built no executable under " .. vim.fn.fnamemodify(root, ":~"), vim.log.levels.WARN)
      return
    end
    local function done(program)
      memory[root].program = program
      callback(program)
    end
    if #programs == 1 then return done(programs[1]) end
    programs = front(programs, memory[root].program)
    vim.ui.select(programs, {
      prompt = "Which executable?",
      format_item = function(path) return vim.fs.relpath(root, path) or path end,
    }, function(choice)
      if choice then done(choice) end
    end)
  end
  if #executables(root) == 0 then return make(root, {}, pick) end
  pick()
end

---@param root string
---@param program string
---@param callback fun(args: string[])
local function ask_args(root, program, callback)
  vim.ui.input({
    prompt = ("Arguments for %s: "):format(vim.fs.basename(program)),
    default = memory[root].args or "",
  }, function(input)
    if input == nil then return end
    memory[root].args = input
    callback(vim.split(vim.trim(input), "%s+", { trimempty = true }))
  end)
end

---@param root string
---@param program string
---@param args string[]
local function run_program(root, program, args)
  require("overseer")
    .new_task({
      name = vim.trim(vim.fs.basename(program) .. " " .. table.concat(args, " ")),
      cmd = vim.list_extend({ program }, args),
      cwd = root,
      -- No `on_complete_dispose`: the output has to outlive a crash.
      components = { "on_exit_set_status", "user_output_pane" },
    })
    :start()
end

---@param root string
---@param program string
---@param args string[]
local function debug_program(root, program, args)
  require("user.debug.adapters").setup()
  require("dap").run {
    type = "codelldb",
    request = "launch",
    name = vim.fs.basename(program),
    program = program,
    args = args,
    cwd = root,
    stopOnEntry = false,
  }
end

---@param launch fun(root: string, program: string, args: string[])
---@param with_args boolean
---@return fun(ctx: user.Context)
local function build_then(launch, with_args)
  return function(ctx)
    local root = assert(root_of(ctx), "no Makefile above this file")
    memory[root] = memory[root] or {}
    choose_program(root, function(program)
      local function go(args)
        make(root, {}, function() launch(root, program, args) end)
      end
      if with_args then return ask_args(root, program, go) end
      go {}
    end)
  end
end

local function command(args)
  return function(ctx) make(assert(root_of(ctx), "no Makefile above this file"), args) end
end

function M.actions()
  local make_ready = vim.fn.executable "make" == 1 or "make is not on PATH"
  return {
    {
      id = "make.build",
      label = "Build the default target",
      category = "Build",
      available = make_ready,
      run = command {},
    },
    {
      id = "make.target",
      label = "Build a target",
      category = "Build",
      available = make_ready,
      run = function(ctx)
        local root = assert(root_of(ctx), "no Makefile above this file")
        memory[root] = memory[root] or {}
        local names = targets(root)
        if #names == 0 then error "make listed no targets" end
        names = front(names, memory[root].target)
        vim.ui.select(names, { prompt = "Make which target?" }, function(choice)
          if not choice then return end
          memory[root].target = choice
          make(root, { choice })
        end)
      end,
    },
    {
      id = "make.rebuild",
      label = "Rebuild everything",
      category = "Build",
      available = make_ready,
      run = command { "-B" },
    },
    {
      id = "make.run",
      label = "Build and run an executable",
      category = "Run",
      available = make_ready,
      run = build_then(run_program, false),
    },
    {
      id = "make.run_args",
      label = "Build and run an executable with arguments",
      category = "Run",
      available = make_ready,
      run = build_then(run_program, true),
    },
    {
      id = "make.debug",
      label = "Build and debug an executable",
      category = "Run",
      available = make_ready,
      run = build_then(debug_program, false),
    },
    {
      id = "make.debug_args",
      label = "Build and debug an executable with arguments",
      category = "Run",
      available = make_ready,
      run = build_then(debug_program, true),
    },
    {
      id = "make.clean",
      label = "Clean with make clean",
      category = "Maintenance",
      available = make_ready,
      run = command { "clean" },
    },
  }
end

function M.status(ctx)
  local root = root_of(ctx)
  if not root then return {} end
  local programs = vim.tbl_map(function(path) return vim.fs.relpath(root, path) or path end, executables(root))
  return { ("  executables: %s"):format(#programs > 0 and table.concat(programs, ", ") or "none built yet") }
end

return M
