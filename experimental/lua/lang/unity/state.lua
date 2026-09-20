local M = {}

--- The bridge writes on change and nothing else, so an editor that has sat idle
--- for an hour has an hour-old file; the only way to tell that from an editor
--- that died is to look at the process.
local LIVENESS_MS = 2000

--- A file replaced by write-then-rename is missing for a moment. A reader woken
--- in that moment should look again rather than conclude it is gone.
local RETRY_MS = 40

---@class unity.State
---@field root string|nil
---@field installed boolean
---@field running boolean
---@field state "idle"|"playing"|"paused"|"compiling"|"importing"|"building"|"unknown"
---@field playing boolean
---@field compiling boolean
---@field errors integer
---@field warnings integer
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
local watching ---@type string|nil

--- The liveness tick re-reads every two seconds; without this stamp it would
--- re-parse every compile message every two seconds to learn nothing.
local diagnostics_stamp ---@type string|nil
local diagnostics_counts = { errors = 0, warnings = 0 }

---@return unity.State
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
  if vim.fn.isdirectory "/proc" == 0 then return true end
  return vim.uv.fs_stat("/proc/" .. pid) ~= nil
end

---@param message string
---@param level integer
local function notify(message, level) vim.notify(message, level, { title = "Unity" }) end

--- Everything worth interrupting for is a transition; nothing here fires on
--- the first read.
---@param previous unity.State
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
    -- Forget where the editor was when it went away, so starting it again is
    -- not reported as a transition out of whatever it was doing last week.
    announced = current.state
  end

  if current.errors ~= previous.errors or current.warnings ~= previous.warnings then
    if current.errors > 0 then
      notify(("Compile failed -- %d error%s"):format(current.errors, current.errors == 1 and "" or "s"), WARN)
    elseif previous.errors > 0 then
      notify("Compile clean", INFO)
    end
  end
end

local read ---@type fun(retrying?: boolean)

---@param retrying? boolean Set on the second look after an apparently missing file.
function read(retrying)
  local root = watching
  if not root then return end

  local bridge = require "lang.unity.bridge"
  local previous = vim.deepcopy(current)

  local state = read_json(bridge.state_file(root))
  if not state and not retrying and bridge.installed(root) then
    -- Possibly caught mid-rename. Look once more before calling it gone.
    if retry then
      retry:stop()
    else
      retry = assert(vim.uv.new_timer())
    end
    retry:start(RETRY_MS, 0, function() vim.schedule(function() read(true) end) end)
    return
  end

  current = vim.deepcopy(EMPTY)
  current.root = root
  current.installed = bridge.installed(root)

  if state and alive(state.pid) then
    current.running = true
    current.state = state.state or "unknown"
    current.playing = state.playing == true or state.paused == true
    current.compiling = state.compiling == true
    current.stale = (state.bridge or 0) < bridge.VERSION
  end

  local diagnostics_file = bridge.diagnostics_file(root)
  local stat = vim.uv.fs_stat(diagnostics_file)
  local stamp = stat and ("%d:%d:%d"):format(stat.mtime.sec, stat.mtime.nsec, stat.size) or nil
  if stamp ~= diagnostics_stamp then
    diagnostics_stamp = stamp
    diagnostics_counts = require("lang.unity.diagnostics").record(root, read_json(diagnostics_file))
  end
  current.errors, current.warnings = diagnostics_counts.errors, diagnostics_counts.warnings

  announce(previous)
end

--- Re-read now, for after something that changes the answer without changing a
--- file.
function M.refresh() read() end

local function unwatch()
  if watcher then
    watcher:stop()
    watcher = nil
  end
end

--- Watching the files themselves does not work: each write replaces the inode
--- and the watch follows the old one into the bin.
---@param root string
---@return boolean
local function watch(root)
  unwatch()
  local dir = require("lang.unity.bridge").watch_dir(root)
  if vim.fn.isdirectory(dir) == 0 then return false end

  watcher = vim.uv.new_fs_event()
  if not watcher then return false end
  -- Several writes can land in one tick; `vim.schedule` coalesces them into
  -- the one read that matters.
  local ok = watcher:start(dir, {}, function() vim.schedule(function() read() end) end)
  if not ok then
    watcher = nil
    return false
  end
  return true
end

--- Idempotent for the same project; switching projects moves the watch rather
--- than adding one.
---@param root string
function M.start(root)
  if watching == root and watcher then return end

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

--- The autocommand hook: start watching whichever project `bufnr` belongs to,
--- if it is a Unity one with the bridge installed. Silent otherwise.
---@param bufnr integer
function M.attach(bufnr)
  local root = require("lang.unity.project").root(bufnr)
  if not root then return end
  if not require("lang.unity.bridge").installed(root) then return end
  M.start(root)
end

return M
