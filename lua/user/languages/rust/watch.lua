-- A continuous build, one per Cargo workspace root.
--
-- The shape is two tasks rather than one `cargo watch -x run`, because a
-- failed build must not take the running program with it. Writing a file
-- restarts the *build* task; only when that build succeeds does the *process*
-- task get restarted from the freshly written artifact. A build that fails
-- leaves the previous process untouched and still on screen.
--
-- The build task is deliberately silent: no output pane, no notification, no
-- dispose-on-complete. Its only user-visible effect is the quickfix list, so a
-- green build is invisible and a red one is `:cnext` away. The process task
-- owns the output pane, since its stdout is the thing you actually watch.
--
-- In `build` mode there is no process task at all -- that is the
-- `hot-lib-reloader` case, where a long-lived host binary `dlopen`s the dylib
-- this rebuilds and swaps it between frames. Restarting anything would defeat
-- the point, so the watcher does nothing but keep the artifact fresh.
local cargo = require "user.languages.rust.cargo"

local M = {}

local TITLE = "Rust watch"

---@class user.rust.Watcher
---@field workspace user.rust.CargoWorkspace
---@field params user.rust.WatchParams
---@field build overseer.Task
---@field process overseer.Task?

--- Watchers that are currently running, keyed by workspace root.
---@type table<string, user.rust.Watcher>
local watchers = {}

--- Parameters chosen for a workspace, kept past a stop so the next toggle does
--- not re-ask. In memory only -- a new Neovim starts from the defaults.
---@type table<string, user.rust.WatchParams>
local remembered = {}

---@param message string
---@param level integer?
local function notify(message, level) vim.notify(message, level or vim.log.levels.INFO, { title = TITLE }) end

--- The workspace the current buffer belongs to.
---@return user.rust.CargoWorkspace? workspace
---@return string? error
function M.here()
  local file = vim.api.nvim_buf_get_name(0)
  return cargo.workspace(file ~= "" and file or vim.fn.getcwd())
end

--- Sensible starting parameters, guessed from how the workspace is built.
---@param workspace user.rust.CargoWorkspace
---@return user.rust.WatchParams
function M.defaults(workspace)
  local lib = cargo.hot_reload_lib(workspace)
  local pkg = lib or workspace.packages[1]
  local bins = lib and {} or cargo.targets(pkg, "bin")

  return {
    -- A project wired for `hot-lib-reloader` wants its dylib rebuilt and
    -- nothing restarted; anything else wants the binary relaunched.
    mode = lib and "build" or "run",
    package = pkg and pkg.name or "",
    target_kind = "bin",
    -- Naming the only binary explicitly costs nothing and keeps `executable`
    -- from having to guess later.
    target = #bins == 1 and bins[1] or "",
    profile = "dev",
    features = {},
    args = {},
    env = {},
    delay = 500,
    paths = {},
    watch_mode = "autocmd",
  }
end

--- The form shown by `:RustWatchConfigure`.
---@param workspace user.rust.CargoWorkspace
---@return table
function M.schema(workspace)
  local packages = vim.tbl_map(function(pkg) return pkg.name end, workspace.packages)

  return {
    mode = {
      desc = "run relaunches the binary each build; build only rebuilds, for a process that reloads itself",
      type = "enum",
      choices = { "run", "build" },
      order = 1,
    },
    package = {
      desc = "Package to build (--package)",
      -- A single-package project has nothing to choose, but an enum of one is
      -- still clearer in the form than a free-text field.
      type = vim.tbl_isempty(packages) and "string" or "enum",
      choices = packages,
      optional = true,
      order = 2,
    },
    target_kind = {
      desc = "Build a binary or an example",
      type = "enum",
      choices = { "bin", "example" },
      order = 3,
    },
    target = {
      desc = "Target name -- leave empty to build the package's only binary",
      type = "string",
      optional = true,
      order = 4,
    },
    profile = {
      desc = "Cargo profile",
      type = "enum",
      choices = { "dev", "release" },
      order = 5,
    },
    features = {
      desc = "Cargo features (--features)",
      type = "list",
      optional = true,
      order = 6,
    },
    args = {
      desc = "Arguments passed to the program itself",
      type = "list",
      optional = true,
      order = 7,
    },
    env = {
      desc = "Environment for the program, as KEY=VALUE",
      type = "list",
      optional = true,
      order = 8,
    },
    delay = {
      desc = "Milliseconds to settle after a write before rebuilding",
      type = "integer",
      order = 9,
    },
    paths = {
      desc = "Only rebuild for writes under these paths -- empty watches the whole project",
      type = "list",
      optional = true,
      order = 10,
    },
    watch_mode = {
      desc = "autocmd watches Neovim's own writes; uv also catches writes from outside Neovim",
      type = "enum",
      choices = { "autocmd", "uv" },
      order = 11,
    },
  }
end

---@param watcher user.rust.Watcher
---@return string
local function build_name(watcher)
  local params = watcher.params
  return ("watch %s"):format(table.concat(cargo.build_args(params), " "))
end

---@param watcher user.rust.Watcher
---@return overseer.Task
local function new_build_task(watcher)
  local params = watcher.params

  local restart = {
    "restart_on_save",
    delay = params.delay,
    mode = params.watch_mode,
    -- A save during a build means that build is already stale.
    interrupt = true,
  }
  -- The component treats an empty path list as "nothing matches", not
  -- "everything matches", so an unset list has to stay unset.
  if params.paths and not vim.tbl_isempty(params.paths) then restart.paths = params.paths end

  local components = {
    "on_exit_set_status",
    restart,
    {
      "on_output_quickfix",
      errorformat = require("user.languages.rust.executor").errorformat,
      -- The only channel this task has. It fills the list but never raises a
      -- window, and never closes one the build did not open.
      open = false,
      open_on_match = false,
      close = false,
      items_only = true,
      -- rust-analyzer (or bacon-ls) already has these on screen inline.
      set_diagnostics = false,
    },
  }
  if params.mode == "run" then table.insert(components, { "user_rust_relaunch", root = watcher.workspace.root }) end

  return require("overseer").new_task {
    name = build_name(watcher),
    cmd = vim.list_extend({ "cargo" }, cargo.build_args(params)),
    cwd = watcher.workspace.root,
    components = components,
  }
end

---@param watcher user.rust.Watcher
---@param exe string
---@return overseer.Task
local function new_process_task(watcher, exe)
  return require("overseer").new_task {
    name = vim.fs.basename(exe),
    cmd = vim.list_extend({ exe }, vim.deepcopy(watcher.params.args or {})),
    cwd = watcher.workspace.root,
    env = cargo.parse_env(watcher.params.env),
    -- No `on_complete_dispose`: when the program exits the buffer has to stay
    -- so the panic that ended it is still readable.
    components = { "on_exit_set_status", "user_output_pane" },
  }
end

--- Start or restart the program, called by `user_rust_relaunch` on a green
--- build. Silent on the happy path; the only thing it reports is being unable
--- to work out what to launch, which is a configuration problem the user has
--- to fix.
---@param root string
function M.relaunch(root)
  local watcher = watchers[root]
  if not watcher or watcher.params.mode ~= "run" then return end

  local exe = cargo.executable(watcher.workspace, watcher.params)
  if not exe then
    notify("Cannot tell which binary to run -- set a target with :RustWatchConfigure", vim.log.levels.WARN)
    return
  end
  if not vim.uv.fs_stat(exe) then
    notify(("Built, but %s is not there"):format(vim.fn.fnamemodify(exe, ":~")), vim.log.levels.WARN)
    return
  end

  if watcher.process and not watcher.process:is_disposed() then
    -- `true` because the program is almost certainly still running; this is
    -- the kill-and-respawn that `build` mode exists to avoid.
    watcher.process:restart(true)
    return
  end

  watcher.process = new_process_task(watcher, exe)
  watcher.process:start()
end

--- Whether a watcher is running for `root`.
---@param root string
---@return boolean
function M.active(root) return watchers[root] ~= nil end

--- The running watcher whose root contains `path`, asking Cargo nothing.
---
--- `here()` would be the honest way to find it, but that shells out to `cargo
--- metadata` on a cold root, and this is called every time the `<Leader>r`
--- picker builds its list. Matching against roots that are already known is
--- enough: a watcher exists or it does not.
---@param path string?
---@return user.rust.Watcher?
local function covering(path)
  if not path or path == "" then path = vim.api.nvim_buf_get_name(0) end
  if path == "" then path = vim.fn.getcwd() end

  local best, best_root
  for root, watcher in pairs(watchers) do
    local rel = vim.fs.relpath(root, path)
    -- The longest matching root wins, for a workspace nested in a workspace.
    if rel and rel:sub(1, 2) ~= ".." and (not best_root or #root > #best_root) then
      best, best_root = watcher, root
    end
  end
  return best
end

---@param watcher user.rust.Watcher
---@return string
local function describe(watcher)
  local params = watcher.params
  return ("%s %s%s"):format(params.mode, params.profile, params.target ~= "" and " " .. params.target or "")
end

--- A one-line description of the watcher on `root`, for a statusline.
---@param root string?
---@return string?
function M.status(root)
  local watcher = root and watchers[root]
  return watcher and ("watch " .. describe(watcher)) or nil
end

--- The same, for whichever watcher covers the current buffer.
---@return string?
function M.status_here()
  local watcher = covering()
  return watcher and describe(watcher) or nil
end

--- Stop the watcher on `root` and drop its tasks.
---@param root string
---@return boolean stopped
function M.stop(root)
  local watcher = watchers[root]
  if not watcher then return false end
  -- Cleared first: stopping the build task completes it, and `relaunch` must
  -- find nothing to relaunch.
  watchers[root] = nil

  for _, task in ipairs { watcher.build, watcher.process } do
    if task and not task:is_disposed() then
      task:stop()
      task:dispose(true)
    end
  end
  return true
end

--- Start a watcher on `workspace` with `params`, replacing any running one.
---@param workspace user.rust.CargoWorkspace
---@param params user.rust.WatchParams
function M.start(workspace, params)
  M.stop(workspace.root)

  local watcher = { workspace = workspace, params = params }
  watcher.build = new_build_task(watcher)
  watchers[workspace.root] = watcher
  watcher.build:start()

  notify(
    ("%s -- %s on save in %s"):format(
      build_name(watcher),
      params.mode == "run" and "rebuild and relaunch" or "rebuild only",
      vim.fn.fnamemodify(workspace.root, ":~")
    )
  )
end

--- Open the parameter form for this buffer's workspace, then start with what
--- comes back. A watcher that was already running is restarted on the new
--- parameters, so a profile or feature change takes effect immediately.
function M.configure()
  local workspace, err = M.here()
  if not workspace then return notify(err or "no Cargo workspace here", vim.log.levels.WARN) end

  local params = vim.deepcopy(remembered[workspace.root] or M.defaults(workspace))
  require("overseer.form").open(TITLE, M.schema(workspace), params, function(result)
    if not result then return end
    remembered[workspace.root] = result
    M.start(workspace, result)
  end)
end

--- The toggle. Stops a running watcher; otherwise starts one, asking for
--- parameters the first time this workspace is watched and reusing them after.
function M.toggle()
  local workspace, err = M.here()
  if not workspace then return notify(err or "no Cargo workspace here", vim.log.levels.WARN) end

  if watchers[workspace.root] then
    M.stop(workspace.root)
    notify(("Stopped watching %s"):format(vim.fn.fnamemodify(workspace.root, ":~")))
    return
  end

  local params = remembered[workspace.root]
  if params then
    M.start(workspace, params)
  else
    M.configure()
  end
end

return M
