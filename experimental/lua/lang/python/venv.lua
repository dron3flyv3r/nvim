local M = {}

local GROUP = "lang_python_venv"
local ROOT_MARKERS = { "pyproject.toml", "setup.py", "setup.cfg", "requirements.txt" }

---@type string|nil
local inherited = vim.env.VIRTUAL_ENV
---@type string|nil
local active
---@type table<string, true>
local nudged = {}

---@param dir string
---@return string|nil
local function venv_in(dir)
  local venv = vim.fs.joinpath(dir, ".venv")
  if vim.fn.executable(vim.fs.joinpath(venv, "bin", "python")) == 1 then return venv end
end

---@param path string|nil a file or a directory
---@return string|nil
local function start_dir(path)
  if not path or path == "" then return nil end
  return vim.fn.isdirectory(path) == 1 and path or vim.fs.dirname(path)
end

---@param path string|nil
---@return string|nil venv the nearest .venv at or above the path
function M.find(path)
  local dir = start_dir(path)
  while dir do
    local venv = venv_in(dir)
    if venv then return venv end
    local parent = vim.fs.dirname(dir)
    dir = parent ~= dir and parent or nil
  end
end

---@param path string|nil
---@return string|nil
function M.root(path)
  local dir = start_dir(path)
  if not dir then return nil end
  local venv = M.find(dir)
  return vim.fs.root(dir, ROOT_MARKERS) or (venv and vim.fs.dirname(venv)) or vim.fs.root(dir, ".git")
end

---@param root string|nil
---@return boolean
function M.is_uv_project(root)
  return root ~= nil and vim.fn.executable "uv" == 1 and vim.uv.fs_stat(vim.fs.joinpath(root, "pyproject.toml")) ~= nil
end

---@return string|nil venv the environment that was active in the shell nv started from
function M.inherited() return inherited end

---@param path string|nil
---@return string|nil
function M.for_path(path) return inherited or M.find(path) end

---@param path string|nil
---@return string
function M.python(path)
  local venv = M.for_path(path)
  if venv then return vim.fs.joinpath(venv, "bin", "python") end
  return vim.fn.exepath "python3" ~= "" and "python3" or "python"
end

---@param path string|nil
---@param name string
---@return string|nil
function M.tool(path, name)
  local venv = M.for_path(path)
  local local_bin = venv and vim.fs.joinpath(venv, "bin", name)
  if local_bin and vim.fn.executable(local_bin) == 1 then return local_bin end
  local found = vim.fn.exepath(name)
  return found ~= "" and found or nil
end

---@return string|nil
function M.active() return inherited or active end

---@param venv string|nil
local function apply(venv)
  if venv == active then return end
  local path = vim.env.PATH or ""
  if active then
    local prefix = vim.fs.joinpath(active, "bin") .. ":"
    if vim.startswith(path, prefix) then path = path:sub(#prefix + 1) end
  end
  if venv then path = vim.fs.joinpath(venv, "bin") .. ":" .. path end
  vim.env.PATH = path
  vim.env.VIRTUAL_ENV = venv
  active = venv
  vim.cmd.redrawstatus()
end

---@param file string
local function nudge(file)
  local root = M.root(file)
  if not root or nudged[root] or not M.is_uv_project(root) then return end
  nudged[root] = true
  vim.notify(
    ("%s has a pyproject.toml but no .venv.\n<Leader>r → Sync the environment with uv"):format(
      vim.fn.fnamemodify(root, ":~")
    ),
    vim.log.levels.INFO,
    { title = "Python" }
  )
end

---@param path string|nil
function M.follow(path)
  if inherited then return end
  local venv = M.find(path)
  apply(venv)
  if not venv and path and vim.fn.isdirectory(path) == 0 then nudge(path) end
end

---@param ctx core.statusline.Context
---@return string|nil
local function component(ctx)
  if vim.bo[ctx.bufnr].filetype ~= "python" then return nil end
  local venv = M.active()
  if not venv then return nil end
  return "󰌠 " .. vim.fs.basename(vim.fs.dirname(venv))
end

---@param buf integer
---@return boolean
local function is_python_file(buf) return vim.bo[buf].filetype == "python" and vim.bo[buf].buftype == "" end

function M.setup()
  require("core.statusline").register("python_venv", { side = "right", order = 5, min_width = 80, text = component })
  if inherited then return end

  local group = vim.api.nvim_create_augroup(GROUP, { clear = true })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    desc = "Activate the .venv of the Python project being edited",
    callback = function(args)
      if is_python_file(args.buf) then M.follow(vim.api.nvim_buf_get_name(args.buf)) end
    end,
  })
  vim.api.nvim_create_autocmd({ "VimEnter", "DirChanged" }, {
    group = group,
    desc = "Activate the .venv of the working directory",
    callback = function()
      local buf = vim.api.nvim_get_current_buf()
      M.follow(is_python_file(buf) and vim.api.nvim_buf_get_name(buf) or vim.fn.getcwd())
    end,
  })
end

return M
