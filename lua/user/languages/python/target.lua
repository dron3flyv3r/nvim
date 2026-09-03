local M = {}

--- Markers for "top of the project" -- the directory that must be on sys.path.
local ROOT_MARKERS = { "pyproject.toml", "setup.py", "setup.cfg", "requirements.txt", ".git" }

---@param root string
---@return string[] prefix, string label
local function interpreter(root)
  local uv_project = vim.uv.fs_stat(vim.fs.joinpath(root, "uv.lock"))
    or vim.uv.fs_stat(vim.fs.joinpath(root, "pyproject.toml"))
  if uv_project and vim.fn.executable "uv" == 1 then return { "uv", "run", "python" }, "uv run" end

  local venv = vim.fs.joinpath(root, ".venv", "bin", "python")
  if vim.uv.fs_stat(venv) then return { venv }, ".venv" end

  local active = vim.env.VIRTUAL_ENV
  if active and vim.uv.fs_stat(vim.fs.joinpath(active, "bin", "python")) then
    return { vim.fs.joinpath(active, "bin", "python") }, "$VIRTUAL_ENV"
  end

  return { "python3" }, "python3"
end

---@param file string
---@param root string
---@return string?
local function module_name(file, root)
  local rel = vim.fs.relpath(root, file)
  if not rel or rel:sub(1, 2) == ".." then return nil end
  local mod = rel:gsub("%.py$", ""):gsub("[/\\]", "."):gsub("%.__init__$", "")
  return mod ~= "" and mod or nil
end

---@class user.PythonTarget
---@field root string       project root; also the cwd every task runs in
---@field py string[]       interpreter command prefix
---@field label string      human name for that interpreter, for task descriptions
---@field module string?    dotted module path, nil if the file is outside the root
---@field file string       absolute path of the file

--- Resolve how to run `file`, or nil if it is not a Python file.
---@param file string? defaults to the current buffer
---@return user.PythonTarget?
function M.resolve(file)
  file = file or vim.api.nvim_buf_get_name(0)
  if file == "" or not file:match "%.py$" then return nil end

  -- A loose script with no project markers still runs; it just has no
  -- meaningful root for `-m` to resolve against, so its own directory is used.
  local root = vim.fs.root(file, ROOT_MARKERS) or vim.fs.dirname(file)
  local py, label = interpreter(root)

  return { root = root, py = py, label = label, module = module_name(file, root), file = file }
end

--- The name of the overseer template for running this target as a module.
--- Kept here so the template and the keymap cannot drift apart.
---@param target user.PythonTarget
---@return string
function M.module_template_name(target) return string.format("python -m %s", target.module) end

return M
