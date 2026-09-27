local project = require "lang.cpp.project"

local M = {}

local LANGUAGES = {
  cpp = { compilers = { "g++", "clang++" }, std = "-std=c++23" },
  c = { compilers = { "gcc", "clang", "cc" }, std = "-std=c23" },
}

---@param proj cpp.Project
---@return string|nil compiler
---@return table|nil language
local function toolchain(proj)
  local language = LANGUAGES[vim.fn.fnamemodify(proj.file, ":e") == "c" and "c" or "cpp"]
  for _, compiler in ipairs(language.compilers) do
    if vim.fn.executable(compiler) == 1 then return compiler, language end
  end
end

---@param proj cpp.Project
---@return cpp.Executable
local function executable(proj)
  local program = vim.fs.joinpath(
    vim.fn.stdpath "cache" --[[@as string]],
    "cpp-run",
    vim.fn.sha256(proj.file):sub(1, 16) .. "-" .. vim.fn.fnamemodify(proj.file, ":t:r")
  )
  return { name = vim.fn.fnamemodify(proj.file, ":t:r"), program = program }
end

---@param proj cpp.Project
---@param on_success? fun()
function M.compile(proj, on_success)
  local compiler, language = toolchain(proj)
  if not compiler or not language then error "no C/C++ compiler on PATH" end
  local exe = executable(proj)
  vim.fn.mkdir(vim.fs.dirname(exe.program), "p")
  project.save(proj.root)
  project.task({
    name = ("%s %s"):format(compiler, vim.fs.basename(proj.file)),
    cmd = { compiler, language.std, "-g", "-O0", "-Wall", "-Wextra", "-o", exe.program, proj.file },
    cwd = proj.root,
  }, on_success)
end

---@param _ cpp.Project
---@param cb fun()
function M.prepare(_, cb) cb() end

---@param proj cpp.Project
---@return cpp.Executable[]
function M.executables(proj) return { executable(proj) } end

---@param proj cpp.Project
---@param _ cpp.Executable
---@param cb fun()
function M.build_executable(proj, _, cb) M.compile(proj, cb) end

---@param proj cpp.Project
---@return string
function M.cwd(proj) return proj.root end

---@param proj cpp.Project
---@return boolean|string
function M.ready(proj) return toolchain(proj) ~= nil or "no gcc, g++ or clang on PATH" end

---@param proj cpp.Project
---@return core.Action[]
function M.actions(proj)
  return {
    {
      id = "file_compile",
      label = "Compile this file on its own",
      category = "Build",
      available = function() return M.ready(proj) end,
      run = function() M.compile(proj) end,
    },
  }
end

---@param proj cpp.Project
---@return string[]
function M.status(proj)
  local compiler = toolchain(proj)
  return {
    "  no CMakeLists.txt or Makefile above this file",
    ("  compiler: %s, binary: %s"):format(compiler or "none", vim.fn.fnamemodify(executable(proj).program, ":~")),
  }
end

return M
