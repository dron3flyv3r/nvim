local file_events = require "user.lsp_file_events"

local M = {}

--- Markers for "top of the project", matching `python_target.lua`.
local ROOT_MARKERS = { "pyproject.toml", "setup.py", "setup.cfg", "requirements.txt", ".git" }

--- Resolved `site-packages` per virtualenv, because the `python3.x` in the path
--- is a glob and only worth expanding once. Only successes are cached, so a
--- virtualenv created mid-session is still found later.
---@type table<string, string>
local resolved = {}

--- Last seen mtime per `site-packages` directory.
---@type table<string, string>
local seen = {}

---@param file string
---@return string?
local function site_packages(file)
  local venvs = {}
  if vim.env.VIRTUAL_ENV and vim.env.VIRTUAL_ENV ~= "" then venvs[#venvs + 1] = vim.env.VIRTUAL_ENV end
  local root = vim.fs.root(file, ROOT_MARKERS)
  if root then venvs[#venvs + 1] = vim.fs.joinpath(root, ".venv") end

  for _, venv in ipairs(venvs) do
    if resolved[venv] then return resolved[venv] end
    -- `lib/python3.13/site-packages` on Unix, `Lib/site-packages` on Windows.
    local hits = vim.fn.glob(vim.fs.joinpath(venv, "lib", "python*", "site-packages"), false, true)
    if not hits[1] then hits = vim.fn.glob(vim.fs.joinpath(venv, "Lib", "site-packages"), false, true) end
    if hits[1] then
      resolved[venv] = hits[1]
      return hits[1]
    end
  end
end

--- Stat the environment behind `bufnr` and tell the servers if it moved.
---@param bufnr integer?  defaults to the current buffer
---@param force boolean?  refresh even if the mtime is unchanged
---@return boolean notified
function M.check(bufnr, force)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].filetype ~= "python" then return false end

  local file = vim.api.nvim_buf_get_name(bufnr)
  if file == "" then return false end
  local dir = site_packages(file)
  if not dir then return false end

  local stat = vim.uv.fs_stat(dir)
  if not stat then return false end
  local mtime = string.format("%d.%d", stat.mtime.sec, stat.mtime.nsec)

  local previously = seen[dir]
  seen[dir] = mtime
  -- Nothing to compare against yet, and nothing to report.
  if not previously then return false end
  if previously == mtime and not force then return false end

  -- The servers attached to this buffer, rather than the ones whose workspace
  -- contains `dir`: an active `$VIRTUAL_ENV` can live outside the project
  -- entirely, and then no workspace contains it.
  file_events.created(dir, vim.lsp.get_clients { bufnr = bufnr })
  return true
end

---@return boolean notified
function M.check_all()
  local notified = false
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then notified = M.check(bufnr) or notified end
  end
  return notified
end

--- The timer `watch` is currently running, if any.
---@type uv.uv_timer_t?
local watcher

---@param timeout_ms integer? default 90s, enough for a cold resolve
function M.watch(timeout_ms)
  local deadline = vim.uv.now() + (timeout_ms or 90000)

  if watcher and not watcher:is_closing() then
    watcher:stop()
    watcher:close()
  end
  local timer = assert(vim.uv.new_timer())
  watcher = timer

  timer:start(
    1000,
    1000,
    vim.schedule_wrap(function()
      if timer:is_closing() then return end
      if M.check_all() or vim.uv.now() >= deadline then
        timer:stop()
        timer:close()
        if watcher == timer then watcher = nil end
      end
    end)
  )
end

--- `:PythonEnvRefresh` -- for an environment change no mtime can show, and as
--- the thing to reach for before `:LspRestart` when something looks stale.
function M.refresh()
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].filetype ~= "python" then
    vim.notify("PythonEnvRefresh: not a Python buffer", vim.log.levels.WARN)
    return
  end
  local dir = site_packages(vim.api.nvim_buf_get_name(bufnr))
  if not dir then
    vim.notify("PythonEnvRefresh: no virtualenv found for this buffer", vim.log.levels.WARN)
    return
  end
  M.check(bufnr, true)
  vim.notify("Re-scanning " .. vim.fn.fnamemodify(dir, ":~"), vim.log.levels.INFO)
end

return M
