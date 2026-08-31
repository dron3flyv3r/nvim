-- Noticing that the virtualenv changed, so a package you just installed is
-- importable without restarting Neovim.
--
-- THE PROBLEM, and it is the same one as `lsp_file_events.lua` one layer out:
-- `uv add rich` in a terminal, come back, and `import rich` is still underlined
-- `Import "rich" could not be resolved`, with no completion on `rich.`. The
-- package is installed and correct; basedpyright resolved that import once,
-- cached the failure, and has no idea the environment moved underneath it.
-- Neovim does not watch files on Linux (the long version of why is at the top
-- of `lsp_file_events.lua`), so nothing tells it.
--
-- WHAT ACTUALLY FIXES IT is one notification. basedpyright keeps a separate
-- *library* watcher from its source watcher, and a `didChangeWatchedFiles`
-- event anywhere under the search path lands in `_libraryUpdated`, which
-- invalidates the import resolver and re-analyses everything (see
-- `invalidateAndForceReanalysis(LibraryWatcherChanged)` in the bundled
-- `pyright-langserver.js`). Pointing it at the `site-packages` directory itself
-- is enough -- it does not need the list of files that arrived, which is
-- convenient, because we do not have one.
--
-- HOW WE KNOW THE ENVIRONMENT MOVED: `site-packages` has an mtime, and it
-- changes whenever an entry is added to or removed from it. So instead of
-- watching anything, `check` stats one directory at moments that already
-- happen anyway -- you focus the window again, you leave a terminal, you enter
-- a Python buffer -- and compares. One `stat` is nothing, it costs exactly zero
-- while you sit still, and it does not care *how* the environment changed:
-- `uv add`, `uv sync`, `uv remove`, `pip install` in a `:terminal`, a task from
-- `<Leader>r`, or a rebuild in a window Neovim never saw.
--
-- The first check on a directory only records the mtime, so opening a project
-- never fires a spurious refresh.
--
-- Wired up in `plugins/lsp-file-events.lua`; `:PythonEnvRefresh` does it by
-- hand for whatever the mtime cannot see.

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

--- The `site-packages` of the virtualenv in use for `file`.
---
--- `$VIRTUAL_ENV` comes first: uv.nvim exports it when it activates an
--- environment, and if one is active it is the one the servers were started
--- with, wherever on disk it lives. `<root>/.venv` is the fallback, and the
--- normal case.
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

--- Check every loaded Python buffer.
---
--- What the window-level triggers use, because they fire while a *terminal* is
--- the current buffer -- you were just in it running `uv add` -- and checking
--- the current buffer would find no Python and no environment. Buffers sharing
--- one virtualenv cost one `stat` between them: the first records the new mtime
--- and the rest see it unchanged.
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

--- Watch for the environment to change over the next `timeout_ms`, then stop.
---
--- For installs started from inside Neovim that never move the cursor:
--- `<Leader>va` and friends run `uv add` in the background and leave you in the
--- same buffer, so none of the "you came back from somewhere" triggers fire,
--- and there is no completion callback to hang this off.
---
--- Bounded on both ends: it stops at the first change it sees, and gives up
--- after `timeout_ms` if the install failed or resolved nothing. A second call
--- replaces the first, so leaning on the keymap does not accumulate timers.
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
