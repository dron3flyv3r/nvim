local project = require "lang.cpp.project"

local M = {}

M.BUILD_TYPES = { "Debug", "RelWithDebInfo", "Release", "MinSizeRel" }

local API = ".cmake/api/v1"

---@param proj cpp.Project
---@return string
function M.build_type(proj) return project.memory(proj.root).build_type or "Debug" end

---@param proj cpp.Project
---@return string
function M.build_dir(proj) return vim.fs.joinpath(proj.root, "build", M.build_type(proj)) end

---@param proj cpp.Project
---@return boolean
local function configured(proj) return vim.uv.fs_stat(vim.fs.joinpath(M.build_dir(proj), "CMakeCache.txt")) ~= nil end

---@param path string
---@return table|nil
local function read_json(path)
  local fd = io.open(path, "r")
  if not fd then return nil end
  local text = fd:read "*a"
  fd:close()
  local ok, data = pcall(vim.json.decode, text)
  return ok and type(data) == "table" and data or nil
end

---@param base string
---@param path string
---@return string
local function absolute(base, path)
  return vim.fs.normalize(vim.startswith(path, "/") and path or vim.fs.joinpath(base, path))
end

--- The File API answers "which targets, which artifacts, which sources" from
--- CMake itself; the query file makes every configure write that answer.
---@param dir string
local function request_codemodel(dir)
  local query = vim.fs.joinpath(dir, API, "query")
  vim.fn.mkdir(query, "p")
  local fd = io.open(vim.fs.joinpath(query, "codemodel-v2"), "a")
  if fd then fd:close() end
end

--- A symlink at the root is where clangd looks, and it follows the build type.
---@param proj cpp.Project
local function link_compile_commands(proj)
  local source = vim.fs.joinpath(M.build_dir(proj), "compile_commands.json")
  local link = vim.fs.joinpath(proj.root, "compile_commands.json")
  if not vim.uv.fs_stat(source) then return end
  local existing = vim.uv.fs_lstat(link)
  if existing and existing.type ~= "link" then return end
  if existing and vim.uv.fs_readlink(link) == source then return end
  if existing then vim.uv.fs_unlink(link) end
  if not vim.uv.fs_symlink(source, link) then return end
  if #vim.lsp.get_clients { name = "clangd" } > 0 then vim.cmd "lsp restart clangd" end
end

---@param proj cpp.Project
---@param on_success? fun()
function M.configure(proj, on_success)
  local dir = M.build_dir(proj)
  request_codemodel(dir)
  local cmd = {
    "cmake",
    "-S",
    proj.root,
    "-B",
    dir,
    "-DCMAKE_BUILD_TYPE=" .. M.build_type(proj),
    "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON",
    "-DCMAKE_COLOR_DIAGNOSTICS=ON",
  }
  -- A generator can only be chosen once per build directory.
  if not configured(proj) and vim.fn.executable "ninja" == 1 then vim.list_extend(cmd, { "-G", "Ninja" }) end
  project.save(proj.root)
  project.task({ name = "cmake configure " .. M.build_type(proj), cmd = cmd, cwd = proj.root }, function()
    link_compile_commands(proj)
    if on_success then on_success() end
  end)
end

---@param proj cpp.Project
---@param cb fun()
function M.prepare(proj, cb)
  if configured(proj) and M.targets(proj) then return cb() end
  M.configure(proj, cb)
end

---@param proj cpp.Project
---@param target? string
---@param on_success? fun()
function M.build(proj, target, on_success)
  M.prepare(proj, function()
    local cmd = { "cmake", "--build", M.build_dir(proj) }
    if target then vim.list_extend(cmd, { "--target", target }) end
    project.save(proj.root)
    project.task({ name = "cmake build " .. (target or "all"), cmd = cmd, cwd = M.build_dir(proj) }, on_success)
  end)
end

---@class cpp.CMakeTarget: cpp.Executable
---@field type string
---@field sources table<string, true>

---@param proj cpp.Project
---@return cpp.CMakeTarget[]|nil
function M.targets(proj)
  local reply = vim.fs.joinpath(M.build_dir(proj), API, "reply")
  if vim.fn.isdirectory(reply) == 0 then return nil end
  local index
  for name in vim.fs.dir(reply) do
    if name:match "^index%-.*%.json$" and (not index or name > index) then index = name end
  end
  local data = index and read_json(vim.fs.joinpath(reply, index))
  if not data then return nil end

  local codemodel
  for _, object in ipairs(data.objects or {}) do
    if object.kind == "codemodel" then codemodel = read_json(vim.fs.joinpath(reply, object.jsonFile)) end
  end
  local configuration = codemodel and codemodel.configurations and codemodel.configurations[1]
  if not configuration then return nil end

  local targets = {}
  for _, ref in ipairs(configuration.targets or {}) do
    local target = read_json(vim.fs.joinpath(reply, ref.jsonFile))
    if target then
      local sources = {}
      for _, source in ipairs(target.sources or {}) do
        sources[absolute(codemodel.paths.source, source.path)] = true
      end
      local artifact = target.artifacts and target.artifacts[1]
      targets[#targets + 1] = {
        name = target.name,
        type = target.type,
        program = artifact and absolute(codemodel.paths.build, artifact.path) or "",
        sources = sources,
      }
    end
  end
  table.sort(targets, function(a, b) return a.name < b.name end)
  return targets
end

---@param proj cpp.Project
---@return cpp.Executable[]
function M.executables(proj)
  local file = proj.file ~= "" and vim.fs.normalize(proj.file) or nil
  local owning, rest = {}, {}
  for _, target in ipairs(M.targets(proj) or {}) do
    if target.type == "EXECUTABLE" then
      if file and target.sources[file] then
        target.label = target.name .. "  (builds this file)"
        owning[#owning + 1] = target
      else
        rest[#rest + 1] = target
      end
    end
  end
  return vim.list_extend(owning, rest)
end

---@param proj cpp.Project
---@param exe cpp.Executable
---@param cb fun()
function M.build_executable(proj, exe, cb) M.build(proj, exe.name, cb) end

---@param proj cpp.Project
---@return string
function M.cwd(proj) return proj.root end

---@return boolean|string
function M.ready()
  if vim.fn.executable "cmake" ~= 1 then return "cmake is not on PATH" end
  return true
end

---@param proj cpp.Project
---@return core.Action[]
function M.actions(proj)
  local memory = project.memory(proj.root)
  return {
    {
      id = "cmake_build",
      label = "Build the project",
      category = "Build",
      available = M.ready,
      run = function() M.build(proj) end,
    },
    {
      id = "cmake_build_target",
      label = "Build a target",
      category = "Build",
      available = M.ready,
      run = function(_, opts)
        if opts.repeated and memory.build_target then return M.build(proj, memory.build_target) end
        M.prepare(proj, function()
          local names = vim.tbl_map(function(target) return target.name end, M.targets(proj) or {})
          vim.ui.select(names, { prompt = "Build which target?" }, function(choice)
            if not choice then return end
            memory.build_target = choice
            M.build(proj, choice)
          end)
        end)
      end,
    },
    {
      id = "cmake_configure",
      label = "Configure the project",
      category = "Build",
      available = M.ready,
      run = function() M.configure(proj) end,
    },
    {
      id = "cmake_build_type",
      label = ("Choose the build type (now %s)"):format(M.build_type(proj)),
      category = "Build",
      repeatable = false,
      run = function()
        vim.ui.select(M.BUILD_TYPES, { prompt = "Build type" }, function(choice)
          if not choice then return end
          memory.build_type = choice
          vim.notify(
            ("Building %s in %s"):format(choice, vim.fn.fnamemodify(M.build_dir(proj), ":~:.")),
            vim.log.levels.INFO,
            { title = "C/C++" }
          )
        end)
      end,
    },
    {
      id = "cmake_test",
      label = "Build and run the tests with CTest",
      category = "Test",
      available = function()
        if vim.fn.executable "ctest" ~= 1 then return "ctest is not on PATH" end
        return M.ready()
      end,
      run = function()
        M.build(
          proj,
          nil,
          function()
            project.task {
              name = "ctest",
              cmd = { "ctest", "--test-dir", M.build_dir(proj), "--output-on-failure" },
              cwd = M.build_dir(proj),
            }
          end
        )
      end,
    },
    {
      id = "cmake_clean",
      label = "Clean the build directory",
      category = "Maintenance",
      available = function() return configured(proj) or "Not configured yet" end,
      run = function()
        project.task {
          name = "cmake clean",
          cmd = { "cmake", "--build", M.build_dir(proj), "--target", "clean" },
          cwd = M.build_dir(proj),
        }
      end,
    },
  }
end

---@param proj cpp.Project
---@return string[]
function M.status(proj)
  local executables = vim.tbl_map(function(exe) return exe.name end, M.executables(proj))
  return {
    ("  build: %s (%s)"):format(vim.fn.fnamemodify(M.build_dir(proj), ":~"), M.build_type(proj)),
    ("  configured: %s"):format(configured(proj) and "yes" or "no"),
    ("  executables: %s"):format(#executables > 0 and table.concat(executables, ", ") or "none known yet"),
  }
end

return M
