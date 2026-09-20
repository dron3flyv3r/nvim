local M = {}

---@class unity.Instance
---@field pid integer
---@field project string|nil
---@field debug_port integer The Mono soft-debugger port, for nvim-dap.
---@field message_port integer The VS/Unity UDP port, for the messenger.

---@param pid integer
---@return string[]|nil argv
local function cmdline(pid)
  local fd = io.open("/proc/" .. pid .. "/cmdline", "rb")
  if not fd then return nil end
  local raw = fd:read "*a"
  fd:close()
  if not raw or raw == "" then return nil end
  return vim.split((raw:gsub("%z$", "")), "%z")
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

--- `-projectPath` is whatever the launcher passed, which for a Hub launch is
--- absolute but for a hand-run editor may not be.
---@param path string
---@return string
local function canonical(path) return (vim.fn.resolve(vim.fn.fnamemodify(path, ":p")):gsub("/$", "")) end

---@return unity.Instance[]
function M.list()
  local dir = vim.uv.fs_scandir "/proc"
  if not dir then return {} end

  local instances = {} ---@type unity.Instance[]
  while true do
    local name = vim.uv.fs_scandir_next(dir)
    if not name then break end

    -- `fs_scandir` reports DT_UNKNOWN for /proc's directories on some kernels,
    -- so filter on the name rather than the type.
    local pid = tonumber(name)
    local process = pid and comm(pid)
    if process and process:lower():find("unity", 1, true) then
      local argv = cmdline(pid)
      if argv then
        local project, batch = nil, false
        for i, arg in ipairs(argv) do
          -- Unity accepts `-batchmode`, its workers are spawned with
          -- `-batchMode`, and the Hub passes `-projectpath`.
          local flag = arg:lower()
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

---@param root string
---@return unity.Instance|nil
function M.for_project(root)
  root = canonical(root)
  for _, instance in ipairs(M.list()) do
    if instance.project == root then return instance end
  end
end

---@param root string
---@return unity.Instance|nil
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

---@param instance unity.Instance
---@return string
function M.describe(instance)
  return ("%s  (pid %d, port %d)"):format(
    instance.project and vim.fs.basename(instance.project) or "unknown project",
    instance.pid,
    instance.debug_port
  )
end

return M
