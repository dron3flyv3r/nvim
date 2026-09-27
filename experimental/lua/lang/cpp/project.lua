local M = {}

M.SOURCES = { "c", "cpp", "objc", "objcpp", "cuda" }

local MAKEFILES = { "GNUmakefile", "makefile", "Makefile" }

-- gcc, clang, ld and CMake itself. Everything else is dropped, so walking the
-- list lands on diagnostics rather than on "[ 40%] Building CXX object".
M.errorformat = table.concat({
  [[%f:%l:%c: fatal %trror: %m]],
  [[%f:%l:%c: %trror: %m]],
  [[%f:%l:%c: %tarning: %m]],
  [[%f:%l:%c: %tote: %m]],
  [[%f:%l: %trror: %m]],
  [[%f:%l: %tarning: %m]],
  [[%f:(%*[^)]): %m]],
  [[CMake %trror at %f:%l (%m):]],
  [[CMake %tarning at %f:%l (%m):]],
  [[CMake %tarning (dev) at %f:%l (%m):]],
  [[%D%*\a[%*\d]: Entering directory %*[`']%f']],
  [[%X%*\a[%*\d]: Leaving directory %*[`']%f']],
  [[%D%*\a: Entering directory %*[`']%f']],
  [[%X%*\a: Leaving directory %*[`']%f']],
  [[%-G%.%#]],
}, ",")

---@class cpp.Project
---@field kind "cmake"|"make"|"file"
---@field root string
---@field file string

---@class cpp.Executable
---@field name string
---@field program string
---@field label? string

---@class cpp.Memory
---@field target? string
---@field args? string
---@field build_target? string
---@field build_type? string

---@param ctx core.Context
---@return string
local function start_of(ctx) return ctx.file ~= "" and vim.fs.dirname(ctx.file) or ctx.cwd end

--- The outermost CMakeLists.txt inside the repository: a subdirectory's own
--- list is part of the project above it, not a project of its own.
---@param start string
---@return string|nil
local function cmake_root(start)
  local git = vim.fs.root(start, ".git")
  local stop = git and vim.fs.dirname(git) or vim.uv.os_homedir()
  local lists = vim.fs.find("CMakeLists.txt", { path = start, upward = true, stop = stop, limit = math.huge })
  return lists[#lists] and vim.fs.dirname(lists[#lists])
end

---@param ctx core.Context
---@return cpp.Project|nil
function M.detect(ctx)
  local start = start_of(ctx)
  local root = cmake_root(start)
  if root then return { kind = "cmake", root = root, file = ctx.file } end
  root = vim.fs.root(start, MAKEFILES)
  if root then return { kind = "make", root = root, file = ctx.file } end
  if (ctx.filetype == "c" or ctx.filetype == "cpp") and ctx.file ~= "" then
    return { kind = "file", root = vim.fs.dirname(ctx.file), file = ctx.file }
  end
end

---@type table<string, cpp.Memory>
local memories = {}

---@param root string
---@return cpp.Memory
function M.memory(root)
  memories[root] = memories[root] or {}
  return memories[root]
end

--- Builds read the disk, so what is on screen is written first.
---@param root string
function M.save(root)
  local prefix = root .. "/"
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    local bo = vim.bo[bufnr]
    if bo.modified and bo.buftype == "" and vim.startswith(vim.api.nvim_buf_get_name(bufnr), prefix) then
      vim.api.nvim_buf_call(bufnr, function() vim.cmd "silent! update" end)
    end
  end
end

---@param spec core.task.Spec
---@param on_success? fun()
function M.task(spec, on_success)
  spec.errorformat = spec.errorformat or M.errorformat
  if on_success then spec.on_exit = function(task)
    if task.status == "success" then on_success() end
  end end
  require("core.task").run(spec)
end

---@param text string
---@return string[]
function M.split(text) return vim.split(vim.trim(text), "%s+", { trimempty = true }) end

---@param exe cpp.Executable
---@param args string[]
---@param cwd string
function M.run(exe, args, cwd)
  if vim.fn.executable(exe.program) ~= 1 then error(("%s was not built: %s"):format(exe.name, exe.program)) end
  require("core.task").run {
    name = vim.trim(("%s %s"):format(exe.name, table.concat(args, " "))),
    cmd = vim.list_extend({ exe.program }, args),
    cwd = cwd,
    -- Started only after a green build, and it may run all day: it must not
    -- hold the queue for the next build.
    queue = false,
  }
end

---@param exe cpp.Executable
---@param args string[]
---@param cwd string
function M.debug(exe, args, cwd)
  if vim.fn.executable(exe.program) ~= 1 then error(("%s was not built: %s"):format(exe.name, exe.program)) end
  require("dap").run {
    type = "codelldb",
    request = "launch",
    name = vim.trim(("%s %s"):format(exe.name, table.concat(args, " "))),
    program = exe.program,
    args = args,
    cwd = cwd,
    stopOnEntry = false,
  }
end

---@return boolean|string
function M.codelldb_ready()
  local adapters = require "plugins.debug.adapters"
  return adapters.codelldb() ~= nil or adapters.install_hint()
end

return M
