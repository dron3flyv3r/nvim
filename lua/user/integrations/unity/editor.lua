local M = {}

---@class UnityInstance
---@field pid integer
---@field project string|nil Absolute path to the project root, if we could read it.
---@field debug_port integer The Mono soft-debugger port -- what nvim-dap attaches to.
---@field message_port integer The VS/Unity UDP port -- what `user.unity_messenger` sends to.

---@param pid integer
---@return string[]|nil argv
local function cmdline(pid)
  local fd = io.open("/proc/" .. pid .. "/cmdline", "rb")
  if not fd then return nil end
  local raw = fd:read "*a"
  fd:close()
  if not raw or raw == "" then return nil end
  -- NUL-separated, with a trailing NUL.
  return vim.split(raw:gsub("%z$", ""), "%z")
end

---@param pid integer
---@return string|nil
local function comm(pid)
  local fd = io.open("/proc/" .. pid .. "/comm", "r")
  if not fd then return nil end
  local name = fd:read "l"
  fd:close()
  return name
end

--- Normalise a project path for comparison: absolute, symlinks resolved, no
--- trailing slash. `-projectPath` is whatever the launcher passed, which for a
--- Hub launch is absolute but for a hand-run editor may not be.
---@param path string
---@return string
local function canonical(path) return (vim.fn.resolve(vim.fn.fnamemodify(path, ":p")):gsub("/$", "")) end

--- Every Unity editor process running for this user, newest pid last.
---@return UnityInstance[]
function M.list()
  local dir = vim.uv.fs_scandir "/proc"
  if not dir then return {} end

  local instances = {} ---@type UnityInstance[]
  while true do
    local name = vim.uv.fs_scandir_next(dir)
    if not name then break end

    local pid = tonumber(name)
    -- `/proc` is full of non-numeric entries (`self`, `cpuinfo`, ...), and
    -- `fs_scandir` gives us `DT_UNKNOWN` for its directories on some kernels,
    -- so filter on the name rather than the type.
    local process = pid and comm(pid)
    if process and process:lower():find("unity", 1, true) then
      local argv = cmdline(pid)
      if argv then
        local project, batch = nil, false
        for i, arg in ipairs(argv) do
          local flag = arg:lower()
          -- Unity accepts `-batchmode`; the workers are spawned with
          -- `-batchMode`; the Hub passes `-projectpath`. Compare lowercased so
          -- every spelling is caught.
          if flag == "-batchmode" then batch = true end
          if flag == "-projectpath" and argv[i + 1] then project = canonical(argv[i + 1]) end
        end
        if not batch and (project or process == "Unity") then
          table.insert(instances, {
            pid = pid,
            project = project,
            debug_port = 56000 + (pid % 1000),
            message_port = 56000 + (pid % 1000) + 2,
          })
        end
      end
    end
  end

  table.sort(instances, function(a, b) return a.pid < b.pid end)
  return instances
end

--- The editor that has `root` open, if one does.
---@param root string
---@return UnityInstance|nil
function M.for_project(root)
  root = canonical(root)
  for _, instance in ipairs(M.list()) do
    if instance.project == root then return instance end
  end
end

--- The editor for `root`, or a notification and nil.
---@param root string
---@return UnityInstance|nil
function M.require_for_project(root)
  local instance = M.for_project(root)
  if not instance then
    vim.notify(
      ("No Unity editor is running with %s open"):format(vim.fs.basename(root)),
      vim.log.levels.WARN,
      { title = "Unity" }
    )
  end
  return instance
end

--- A one-line label for pickers and notifications.
---@param instance UnityInstance
---@return string
function M.describe(instance)
  return ("%s  (pid %d, port %d)"):format(
    instance.project and vim.fs.basename(instance.project) or "unknown project",
    instance.pid,
    instance.debug_port
  )
end

return M
