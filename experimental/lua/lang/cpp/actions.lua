local project = require "lang.cpp.project"

local BACKENDS = {
  cmake = require "lang.cpp.cmake",
  make = require "lang.cpp.make",
  file = require "lang.cpp.file",
}

local DETAIL = { cmake = "CMake project", make = "Makefile project", file = "single file" }

local HANDLED = { cmake = true, make = true }
for _, ft in ipairs(project.SOURCES) do
  HANDLED[ft] = true
end

---@param ctx core.Context
---@return cpp.Project|nil
local function detect(ctx)
  if not HANDLED[ctx.filetype] then return nil end
  return project.detect(ctx)
end

---@param proj cpp.Project
---@param opts core.ActionRunOpts
---@param prompt string
---@param callback fun(exe: cpp.Executable)
local function choose(proj, opts, prompt, callback)
  local backend = BACKENDS[proj.kind]
  local memory = project.memory(proj.root)
  backend.prepare(proj, function()
    local executables = backend.executables(proj)
    if #executables == 0 then
      vim.notify("This project builds no executables", vim.log.levels.WARN, { title = "C/C++" })
      return
    end
    local function pick(exe)
      memory.target = exe.name
      callback(exe)
    end
    if opts.repeated and memory.target then
      for _, exe in ipairs(executables) do
        if exe.name == memory.target then return pick(exe) end
      end
    end
    if #executables == 1 then return pick(executables[1]) end
    vim.ui.select(executables, {
      prompt = prompt,
      format_item = function(exe) return exe.label or exe.name end,
    }, function(choice)
      if choice then pick(choice) end
    end)
  end)
end

---@param proj cpp.Project
---@param opts core.ActionRunOpts
---@param exe cpp.Executable
---@param callback fun(args: string[])
local function arguments(proj, opts, exe, callback)
  local memory = project.memory(proj.root)
  if opts.repeated and memory.args then return callback(project.split(memory.args)) end
  vim.ui.input({ prompt = ("Arguments for %s: "):format(exe.name), default = memory.args or "" }, function(input)
    if input == nil then return end
    memory.args = input
    callback(project.split(input))
  end)
end

---@param proj cpp.Project
---@param mode "run"|"debug"
---@param with_args boolean
---@return fun(ctx: core.Context, opts: core.ActionRunOpts)
local function launcher(proj, mode, with_args)
  local backend = BACKENDS[proj.kind]
  return function(_, opts)
    choose(proj, opts, mode == "run" and "Run which executable?" or "Debug which executable?", function(exe)
      local function go(args)
        backend.build_executable(proj, exe, function() project[mode](exe, args, backend.cwd(proj)) end)
      end
      if with_args then return arguments(proj, opts, exe, go) end
      go {}
    end)
  end
end

---@param proj cpp.Project
---@return core.Action[]
local function launch_actions(proj)
  local backend = BACKENDS[proj.kind]
  local function buildable() return backend.ready(proj) end
  local function debuggable()
    local ready = project.codelldb_ready()
    if ready ~= true then return ready end
    return backend.ready(proj)
  end
  return {
    {
      id = "run",
      label = "Build and run an executable",
      category = "Run",
      available = buildable,
      run = launcher(proj, "run", false),
    },
    {
      id = "run_args",
      label = "Build and run an executable with arguments",
      category = "Run",
      available = buildable,
      run = launcher(proj, "run", true),
    },
    {
      id = "debug",
      label = "Build and debug an executable",
      category = "Debug",
      available = debuggable,
      run = launcher(proj, "debug", false),
    },
    {
      id = "debug_args",
      label = "Build and debug an executable with arguments",
      category = "Debug",
      available = debuggable,
      run = launcher(proj, "debug", true),
    },
  }
end

---@type core.ActionProvider
return {
  id = "cpp",
  name = "C/C++",
  priority = 80,

  detect = function(ctx)
    local proj = detect(ctx)
    if not proj then return false end
    return ("%s at %s"):format(DETAIL[proj.kind], vim.fn.fnamemodify(proj.root, ":~"))
  end,

  actions = function(ctx)
    local proj = detect(ctx)
    if not proj then return {} end
    return vim.list_extend(BACKENDS[proj.kind].actions(proj), launch_actions(proj))
  end,

  status = function(ctx)
    local proj = detect(ctx)
    if not proj then return {} end
    local memory = project.memory(proj.root)
    local lines = BACKENDS[proj.kind].status(proj)
    lines[#lines + 1] = ("  last executable: %s, arguments: %s"):format(memory.target or "none", memory.args or "none")
    return lines
  end,
}
