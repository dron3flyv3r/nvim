local M = {}

--- How often the liveness check runs. The bridge writes on change and nothing
--- else, so an editor that has sat idle for an hour has an hour-old file; the
--- only way to tell that from an editor that died is to look at the process.
local LIVENESS_MS = 2000

--- A file replaced by write-then-rename is missing for a moment. A reader woken
--- in that moment should look again rather than conclude it is gone.
local RETRY_MS = 40

--- What the statusline and the notifications are both looking at.
---@class UnityState
---@field root string|nil The project being watched.
---@field installed boolean Whether the bridge is in the project at all.
---@field running boolean Whether an editor with the bridge loaded is alive.
---@field state string One of `idle`, `playing`, `paused`, `compiling`, `importing`, `building`, or `unknown`.
---@field playing boolean
---@field compiling boolean
---@field errors integer From the last compile.
---@field warnings integer From the last compile.
---@field stale boolean The bridge is older than this config expects.
local EMPTY = {
  root = nil,
  installed = false,
  running = false,
  state = "unknown",
  playing = false,
  compiling = false,
  errors = 0,
  warnings = 0,
  stale = false,
}

local current = vim.deepcopy(EMPTY)

--- `nil` until the first read, so the first read seeds without announcing a
--- transition into the state Unity was already in before Neovim started.
local announced ---@type string|nil

local watcher ---@type uv.uv_fs_event_t|nil
local timer ---@type uv.uv_timer_t|nil
local retry ---@type uv.uv_timer_t|nil
local watching ---@type string|nil The root `start` was last called with.

--- Size and mtime of `diagnostics.json` as it was last read, and what it said.
--- The liveness tick re-reads every two seconds; without this it would re-parse
--- every compile message every two seconds to learn nothing.
local diagnostics_stamp ---@type string|nil
local diagnostics_counts = { errors = 0, warnings = 0 }

--- The one-time wiring, done on the first project rather than at startup: a
--- session that never opens a Unity file never pays for any of this.
local did_setup = false

--- The current state. Cheap: everything here is already in memory, which is
--- what makes it safe to call from a statusline provider.
---@return UnityState
function M.get() return current end

---@param path string
---@return table|nil
local function read_json(path)
  local file = io.open(path, "r")
  if not file then return nil end
  local content = file:read "*a"
  file:close()
  if not content or content == "" then return nil end
  local ok, decoded = pcall(vim.json.decode, content)
  return ok and type(decoded) == "table" and decoded or nil
end

---@param pid integer|nil
---@return boolean
local function alive(pid)
  if not pid then return false end
  -- Every other part of this integration reads `/proc` already; where there is
  -- none, the file's own existence is the best answer available.
  if vim.fn.isdirectory "/proc" == 0 then return true end
  return vim.uv.fs_stat("/proc/" .. pid) ~= nil
end

---@param message string
---@param level integer
local function notify(message, level) vim.notify(message, level, { title = "Unity" }) end

--- Say what changed, once. Everything worth interrupting for is a transition;
--- nothing here fires on the first read.
---@param previous UnityState
local function announce(previous)
  local INFO, WARN = vim.log.levels.INFO, vim.log.levels.WARN

  if announced == nil then
    announced = current.state
    return
  end

  if previous.running and not current.running then
    notify("Editor closed", INFO)
  elseif not previous.running and current.running then
    notify("Editor ready", INFO)
  end

  if current.running and current.state ~= announced then
    local from, to = announced, current.state
    announced = to
    if to == "playing" and from == "paused" then
      notify("Resumed", INFO)
    elseif to == "playing" then
      notify("Play mode", INFO)
    elseif to == "paused" then
      notify("Paused", INFO)
    elseif to == "building" then
      notify("Building player", INFO)
    elseif from == "building" then
      notify("Build finished", INFO)
    elseif from == "playing" or from == "paused" then
      notify("Left play mode", INFO)
    end
  elseif not current.running then
    -- Forget where the editor was when it went away, so that starting it again
    -- is not reported as a transition out of whatever it was doing last week.
    announced = current.state
  end

  -- The compile result, which is the one notification worth reading: the count
  -- only moves when a compile has just finished writing its messages.
  if current.errors ~= previous.errors or current.warnings ~= previous.warnings then
    if current.errors > 0 then
      notify(("Compile failed -- %d error%s"):format(current.errors, current.errors == 1 and "" or "s"), WARN)
    elseif previous.errors > 0 then
      notify("Compile clean", INFO)
    end
  end
end

local read ---@type fun(retrying?: boolean)

--- Re-read both files and make what they say the current state.
---@param retrying? boolean Set on the second look after an apparently missing file.
function read(retrying)
  local root = watching
  if not root then return end

  local companion = require "user.integrations.unity.companion"
  local previous = vim.deepcopy(current)

  local state = read_json(companion.state_file(root))
  if not state and not retrying and companion.installed(root) then
    -- Possibly caught mid-rename. Look once more before calling it gone.
    if retry then
      retry:stop()
    else
      retry = assert(vim.uv.new_timer())
    end
    retry:start(RETRY_MS, 0, function()
      vim.schedule(function() read(true) end)
    end)
    return
  end

  current = vim.deepcopy(EMPTY)
  current.root = root
  current.installed = companion.installed(root)

  if state and alive(state.pid) then
    current.running = true
    current.state = state.state or "unknown"
    current.playing = state.playing == true or state.paused == true
    current.compiling = state.compiling == true
    current.stale = (state.bridge or 0) < companion.VERSION
  end

  local diagnostics_file = companion.diagnostics_file(root)
  local stat = vim.uv.fs_stat(diagnostics_file)
  local stamp = stat and ("%d:%d:%d"):format(stat.mtime.sec, stat.mtime.nsec, stat.size) or nil
  if stamp ~= diagnostics_stamp then
    diagnostics_stamp = stamp
    diagnostics_counts = require("user.integrations.unity.diagnostics").record(root, read_json(diagnostics_file))
  end
  current.errors, current.warnings = diagnostics_counts.errors, diagnostics_counts.warnings

  announce(previous)
  vim.api.nvim_exec_autocmds("User", { pattern = "UnityState", modeline = false })
end

--- Re-read now. For after something that changes the answer without changing a
--- file, such as installing the bridge.
function M.refresh() read() end

local function unwatch()
  if watcher then
    watcher:stop()
    watcher = nil
  end
end

--- Watch the bridge's directory. Watching the files themselves does not work:
--- each write replaces the inode, and the watch follows the old one into the
--- bin. Returns whether there was a directory to watch at all.
---@param root string
---@return boolean
local function watch(root)
  unwatch()
  local dir = require("user.integrations.unity.companion").watch_dir(root)
  if vim.fn.isdirectory(dir) == 0 then return false end

  watcher = vim.uv.new_fs_event()
  if not watcher then return false end
  local ok = watcher:start(dir, {}, function()
    -- Several writes can land in one tick; `vim.schedule` coalesces them into
    -- the one read that matters.
    vim.schedule(function() read() end)
  end)
  if not ok then
    watcher = nil
    return false
  end
  return true
end

--- Follow `root`'s editor. Idempotent for the same project; switching projects
--- moves the watch rather than adding one.
---@param root string
function M.start(root)
  if watching == root and watcher then return end

  if not did_setup then
    did_setup = true
    require("user.integrations.unity.statusline").setup()
  end

  M.stop()
  watching = root
  announced = nil

  watch(root)
  timer = assert(vim.uv.new_timer())
  timer:start(
    LIVENESS_MS,
    LIVENESS_MS,
    vim.schedule_wrap(function()
      if not watching then return end
      -- Re-arm the watch if the directory only just appeared, and re-read
      -- either way: a dead editor leaves its file behind, and no file event
      -- will ever tell us about it.
      if not watcher then watch(watching) end
      read()
    end)
  )
  read()
end

function M.stop()
  unwatch()
  for _, handle in ipairs { timer, retry } do
    if handle then
      handle:stop()
      if not handle:is_closing() then handle:close() end
    end
  end
  timer, retry, watching, announced = nil, nil, nil, nil
  diagnostics_stamp, diagnostics_counts = nil, { errors = 0, warnings = 0 }
  current = vim.deepcopy(EMPTY)
end

--- Start watching whichever project `bufnr` belongs to, if it is a Unity one
--- with the bridge installed. The autocmd hook; deliberately silent otherwise.
---@param bufnr integer
function M.attach(bufnr)
  local root = require("user.integrations.unity").root(bufnr)
  if not root then return end
  if not require("user.integrations.unity.companion").installed(root) then return end
  M.start(root)
end

return M
