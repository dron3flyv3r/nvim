local M = {}

local root
local read_stdin = false
local autosave = true

local function project_root()
  local cwd = vim.uv.cwd()
  return vim.fs.root(cwd, ".git") or cwd
end

local function session_path()
  local directory = vim.fs.joinpath(vim.fn.stdpath "state" --[[@as string]], "sessions")
  return directory, vim.fs.joinpath(directory, vim.fs.slug(root) .. ".vim")
end

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "session" })
end

---@param opts? { quiet?: boolean }
---@return boolean
function M.save(opts)
  opts = opts or {}
  if opts.quiet and not autosave then return false end
  autosave = true
  local directory, path = session_path()
  vim.fs.mkdir(directory, { parents = true })

  local ok, err = pcall(vim.cmd, "silent mksession! " .. vim.fn.fnameescape(path))
  if not ok then
    notify(err, vim.log.levels.ERROR)
    return false
  end
  if not opts.quiet then notify("Saved " .. root) end
  return true
end

---@param opts? { quiet?: boolean }
---@return boolean
function M.restore(opts)
  opts = opts or {}
  local _, path = session_path()
  if not vim.uv.fs_stat(path) then
    if not opts.quiet then notify("No saved session for " .. root, vim.log.levels.WARN) end
    return false
  end

  local ok, err = pcall(vim.cmd, "silent source " .. vim.fn.fnameescape(path))
  if not ok then
    notify(err, vim.log.levels.ERROR)
    return false
  end
  if not opts.quiet then notify("Restored " .. root) end
  return true
end

---@return boolean
function M.delete()
  local _, path = session_path()
  if not vim.uv.fs_stat(path) then
    notify("No saved session for " .. root, vim.log.levels.WARN)
    return false
  end

  local ok, err = vim.uv.fs_unlink(path)
  if not ok then
    notify(err, vim.log.levels.ERROR)
    return false
  end
  autosave = false
  notify("Deleted " .. root)
  return true
end

function M.mark_stdin() read_stdin = true end

function M.restore_on_start()
  if read_stdin or vim.fn.argc(-1) > 0 or vim.o.diff then return end
  M.restore { quiet = true }
end

function M.setup()
  root = project_root()
  vim.api.nvim_create_user_command("SessionSave", M.save, {})
  vim.api.nvim_create_user_command("SessionRestore", M.restore, {})
  vim.api.nvim_create_user_command("SessionDelete", M.delete, {})
end

return M
