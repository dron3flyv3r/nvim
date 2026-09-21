local M = {}

local root
local read_stdin = false
local attached = false
local started_from_directory = false

local function project_root()
  -- `vim.uv.cwd()` fails outright when the directory has been deleted underneath
  -- the shell, and `vim.fs.root` asserts on the nil. Neovim's own idea of the
  -- working directory survives that, because it is a remembered string.
  local cwd = vim.uv.cwd() or vim.fn.getcwd()
  if cwd == "" then cwd = assert(vim.uv.os_homedir()) end
  return vim.fs.root(cwd, ".git") or cwd
end

local function session_path()
  local directory = vim.fs.joinpath(vim.fn.stdpath "state" --[[@as string]], "sessions")
  return directory, vim.fs.joinpath(directory, vim.fs.slug(root) .. ".vim")
end

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "session" })
end

---@param name string
---@return boolean
local function is_uri(name) return name:match "^%a[%w+.%-]*://" ~= nil end

-- A URI-named buffer belongs to whatever invented the scheme. Neovim restores it
-- as an ordinary empty file buffer, and the plugin then finds the name already
-- taken and reuses that empty buffer rather than filling a new one -- which is
-- how quitting with a review open left every diff in the project with a blank
-- old side. They are dropped on the way back in, whatever wrote them.
local function drop_uri_buffers()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if is_uri(vim.api.nvim_buf_get_name(buf)) and #vim.api.nvim_list_wins() > 1 then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if is_uri(vim.api.nvim_buf_get_name(buf)) then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
  end
end

-- Only the ones nothing is showing: a window still on one belongs to something
-- live, and closing it here would be this function deciding to end a review.
local function forget_hidden_uri_buffers()
  local shown = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    shown[vim.api.nvim_win_get_buf(win)] = true
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if not shown[buf] and is_uri(vim.api.nvim_buf_get_name(buf)) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
end

---@return boolean
local function holds_a_file()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[buf].buflisted and vim.bo[buf].buftype == "" and vim.api.nvim_buf_get_name(buf) ~= "" then return true end
  end
  return false
end

---@param opts? { quiet?: boolean }
---@return boolean
function M.save(opts)
  opts = opts or {}
  -- An exit that happens to hold nothing -- a one-file visit, a project closed
  -- buffer by buffer -- must not replace the layout that is stored for it.
  if opts.quiet and (not attached or not holds_a_file()) then return false end
  attached = true
  forget_hidden_uri_buffers()
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
  drop_uri_buffers()
  attached = true
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
  attached = false
  notify("Deleted " .. root)
  return true
end

function M.mark_stdin() read_stdin = true end

---@return string?
local function directory_argument()
  if vim.fn.argc(-1) ~= 1 then return end
  local path = vim.fn.fnamemodify(vim.fn.argv(0) --[[@as string]], ":p")
  local stat = vim.uv.fs_stat(path)
  return stat and stat.type == "directory" and path or nil
end

local function wipe_directory_buffers()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if name ~= "" and vim.fn.isdirectory(name) == 1 then vim.api.nvim_buf_delete(buf, { force = true }) end
  end
end

-- Runs before lazy loads the explorer, which otherwise claims the directory
-- buffer on the first BufEnter and takes the window the session is about to
-- restore into.
local function adopt_directory_argument()
  if vim.o.diff then return end
  local directory = directory_argument()
  if not directory then return end

  vim.cmd.cd(vim.fn.fnameescape(directory))
  vim.cmd "silent %argdel"
  wipe_directory_buffers()
  started_from_directory = true
end

function M.restore_on_start()
  if read_stdin or vim.o.diff then return end
  if not started_from_directory and vim.fn.argc(-1) > 0 then return end
  attached = true
  M.restore { quiet = true }
end

function M.setup()
  adopt_directory_argument()
  root = project_root()
  vim.api.nvim_create_user_command("SessionSave", M.save, {})
  vim.api.nvim_create_user_command("SessionRestore", M.restore, {})
  vim.api.nvim_create_user_command("SessionDelete", M.delete, {})
end

return M
