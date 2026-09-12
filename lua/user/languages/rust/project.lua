-- `cargo add` changes what compiles without touching a single buffer.
-- rust-analyzer notices on its own, but bacon-ls (see `rust-lsp.lua`, which
-- hands it compiler diagnostics) pushes diagnostics and only replaces them
-- after another Cargo run. Nothing schedules that run, so the unresolved-import
-- error stays on screen against a project that now builds.
local file_events = require "user.lsp_file_events"

local M = {}

local MANIFEST = "Cargo.toml"
local WATCHED = { "Cargo.toml", "Cargo.lock" }

--- Last seen manifest mtimes per project root.
---@type table<string, string>
local seen = {}

---@param bufnr integer
---@return string?
local function root_of(bufnr)
  local file = vim.api.nvim_buf_get_name(bufnr)
  return vim.fs.root(file ~= "" and file or vim.fn.getcwd(), MANIFEST)
end

---@param root string
---@return string
local function signature(root)
  local parts = {}
  for _, name in ipairs(WATCHED) do
    local stat = vim.uv.fs_stat(vim.fs.joinpath(root, name))
    parts[#parts + 1] = stat and ("%d.%d"):format(stat.mtime.sec, stat.mtime.nsec) or "-"
  end
  return table.concat(parts, " ")
end

---@param client vim.lsp.Client
---@param root string
---@return boolean
local function owns(client, root)
  if not client.root_dir then return true end
  local rel = vim.fs.relpath(client.root_dir, root)
  return rel ~= nil and rel:sub(1, 2) ~= ".."
end

--- bacon-ls advertises one `workspace/executeCommand`, `bacon_ls.run`, which
--- starts a Cargo run immediately. Read the name off the server rather than
--- hard-coding it, so a rename upstream degrades to doing nothing.
---@param client vim.lsp.Client
---@return string?
local function run_command(client)
  local commands = vim.tbl_get(client, "server_capabilities", "executeCommandProvider", "commands") or {}
  for _, name in ipairs(commands) do
    if name:match "%.run$" then return name end
  end
end

--- Tell every Rust server that this project's manifests moved.
---@param root string
---@param reload boolean? also make rust-analyzer re-read the workspace
---@return boolean rechecked whether a diagnostics run was requested
function M.refresh_root(root, reload)
  for _, name in ipairs(WATCHED) do
    local path = vim.fs.joinpath(root, name)
    if vim.uv.fs_stat(path) then file_events.changed(path) end
  end

  local rechecked = false
  for _, client in ipairs(vim.lsp.get_clients()) do
    local name = client.name:gsub("%-", "_")
    if owns(client, root) then
      if name == "bacon_ls" then
        local command = run_command(client)
        if command then
          client:request("workspace/executeCommand", { command = command, arguments = {} }, function() end)
          rechecked = true
        end
      elseif reload and name == "rust_analyzer" then
        client:request("rust-analyzer/reloadWorkspace", nil, function() end)
      end
    end
  end
  return rechecked
end

--- Stat the manifests behind `bufnr` and refresh if they moved.
---@param bufnr integer? defaults to the current buffer
---@return boolean refreshed
function M.check(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then return false end
  local file = vim.api.nvim_buf_get_name(bufnr)
  if vim.bo[bufnr].filetype ~= "rust" and vim.fs.basename(file) ~= MANIFEST then return false end

  local root = root_of(bufnr)
  if not root then return false end

  local current = signature(root)
  local previously = seen[root]
  seen[root] = current
  -- Nothing to compare against yet, and nothing to report.
  if not previously or previously == current then return false end

  M.refresh_root(root)
  return true
end

---@return boolean refreshed
function M.check_all()
  local refreshed = false
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then refreshed = M.check(bufnr) or refreshed end
  end
  return refreshed
end

--- The timer `watch` is currently running, if any.
---@type uv.uv_timer_t?
local watcher

--- Poll until a manifest changes, for the window where `cargo add` is running
--- as a task and no focus or terminal event will fire when it finishes.
---@param timeout_ms integer? default 60s, enough for a cold registry fetch
function M.watch(timeout_ms)
  local deadline = vim.uv.now() + (timeout_ms or 60000)

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

--- `:RustProjectRefresh` -- for a dependency change no mtime can show, and as
--- the thing to reach for before `:LspRestart` when diagnostics look stale.
function M.refresh()
  local root = root_of(vim.api.nvim_get_current_buf())
  if not root then
    vim.notify("RustProjectRefresh: no Cargo.toml above this buffer", vim.log.levels.WARN, { title = "Rust" })
    return
  end
  seen[root] = signature(root)
  local rechecked = M.refresh_root(root, true)
  vim.notify(
    ("Reloading %s%s"):format(
      vim.fn.fnamemodify(root, ":~"),
      rechecked and "" or " -- no diagnostics server to recheck"
    ),
    vim.log.levels.INFO,
    { title = "Rust" }
  )
end

return M
