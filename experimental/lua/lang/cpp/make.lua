local project = require "lang.cpp.project"

local M = {}

local SKIP_DIRS = { [".git"] = true, CMakeFiles = true, node_modules = true }

---@param proj cpp.Project
---@param args string[]
---@param on_success? fun()
function M.make(proj, args, on_success)
  project.save(proj.root)
  local cmd = vim.list_extend({ "make" }, args)
  project.task({ name = table.concat(cmd, " "), cmd = cmd, cwd = proj.root }, on_success)
end

--- Parsed from make's own database, so includes and generated rules count.
--- Blocking, but only ever reached from a keypress.
---@param proj cpp.Project
---@return string[]
function M.targets(proj)
  local result = vim
    .system({ "make", "-npq", "-C", proj.root, ".DEFAULT" }, { text = true, env = { LC_ALL = "C" } })
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

--- A Makefile does not say what it produces, so the answer is whatever ELF
--- executables sit under the root, newest first.
---@param proj cpp.Project
---@return cpp.Executable[]
function M.executables(proj)
  local found = {}
  for name, kind in
    vim.fs.dir(proj.root, {
      depth = 3,
      skip = function(dir) return not SKIP_DIRS[vim.fs.basename(dir)] end,
    })
  do
    local path = vim.fs.joinpath(proj.root, name)
    if kind == "file" and not name:match "%.so[%.%d]*$" and vim.fn.executable(path) == 1 and is_elf(path) then
      local stat = vim.uv.fs_stat(path)
      found[#found + 1] = { name = name, program = path, mtime = stat and stat.mtime.sec or 0 }
    end
  end
  table.sort(found, function(a, b) return a.mtime > b.mtime end)
  return found
end

---@param proj cpp.Project
---@param cb fun()
function M.prepare(proj, cb)
  if #M.executables(proj) > 0 then return cb() end
  M.make(proj, {}, cb)
end

---@param proj cpp.Project
---@param _ cpp.Executable
---@param cb fun()
function M.build_executable(proj, _, cb) M.make(proj, {}, cb) end

---@param proj cpp.Project
---@return string
function M.cwd(proj) return proj.root end

---@return boolean|string
function M.ready()
  if vim.fn.executable "make" ~= 1 then return "make is not on PATH" end
  return true
end

---@param proj cpp.Project
---@return core.Action[]
function M.actions(proj)
  local memory = project.memory(proj.root)
  return {
    {
      id = "make_build",
      label = "Build the default target",
      category = "Build",
      available = M.ready,
      run = function() M.make(proj, {}) end,
    },
    {
      id = "make_build_target",
      label = "Build a target",
      category = "Build",
      available = M.ready,
      run = function(_, opts)
        if opts.repeated and memory.build_target then return M.make(proj, { memory.build_target }) end
        local targets = M.targets(proj)
        if #targets == 0 then error "make listed no targets" end
        vim.ui.select(targets, { prompt = "Make which target?" }, function(choice)
          if not choice then return end
          memory.build_target = choice
          M.make(proj, { choice })
        end)
      end,
    },
    {
      id = "make_rebuild",
      label = "Rebuild everything",
      category = "Build",
      available = M.ready,
      run = function() M.make(proj, { "-B" }) end,
    },
    {
      id = "make_clean",
      label = "Clean with make clean",
      category = "Maintenance",
      available = M.ready,
      run = function() M.make(proj, { "clean" }) end,
    },
  }
end

---@param proj cpp.Project
---@return string[]
function M.status(proj)
  local executables = vim.tbl_map(function(exe) return exe.name end, M.executables(proj))
  return {
    ("  executables: %s"):format(#executables > 0 and table.concat(executables, ", ") or "none built yet"),
  }
end

return M
