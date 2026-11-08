local M = {}

---@class core.remote.Host
---@field name string the label, and the key the store is indexed by
---@field dest string the ssh destination
---@field projects string[] the registered project directories
---@field last? string the project opened most recently
---@field browsed? string where quick edit was last browsing

---@type core.remote.Host[]
local hosts = {}
local loaded = false

---@param message string
---@param level? integer
local function notify(message, level) vim.notify(message, level or vim.log.levels.INFO, { title = "Remote" }) end

---@return string
local function store()
  local dir = vim.fs.joinpath(vim.fn.stdpath "state" --[[@as string]], "remote")
  return vim.fs.joinpath(dir, "hosts.json")
end

local function load()
  if loaded then return end
  loaded, hosts = true, {}
  local file = io.open(store(), "r")
  if not file then return end
  local ok, decoded = pcall(vim.json.decode, file:read "*a")
  file:close()
  if not ok or type(decoded) ~= "table" or type(decoded.hosts) ~= "table" then return end
  for _, entry in ipairs(decoded.hosts) do
    if type(entry) == "table" and type(entry.name) == "string" and type(entry.dest) == "string" then
      hosts[#hosts + 1] = {
        name = entry.name,
        dest = entry.dest,
        projects = type(entry.projects) == "table" and entry.projects or {},
        last = type(entry.last) == "string" and entry.last or nil,
        browsed = type(entry.browsed) == "string" and entry.browsed or nil,
      }
    end
  end
end

local function save()
  local path = store()
  vim.fs.mkdir(vim.fs.dirname(path), { parents = true })
  vim.fn.writefile({ vim.json.encode { hosts = hosts } }, path)
end

---@return core.remote.Host[]
function M.all()
  load()
  return hosts
end

---@param name string
---@return core.remote.Host|nil
function M.get(name)
  for _, host in ipairs(M.all()) do
    if host.name == name then return host end
  end
end

---@param dest string
---@param name? string
---@return core.remote.Host|nil
function M.add(dest, name)
  dest = vim.trim(dest)
  if dest == "" then return nil end
  name = name and vim.trim(name) or nil
  if not name or name == "" then name = dest:match "@(.+)$" or dest end
  load()
  if M.get(name) then
    notify(name .. " is already a known host", vim.log.levels.WARN)
    return nil
  end
  local host = { name = name, dest = dest, projects = {} }
  hosts[#hosts + 1] = host
  save()
  notify(("Added %s (%s)"):format(name, dest))
  return host
end

---@param name string
function M.remove(name)
  load()
  for index, host in ipairs(hosts) do
    if host.name == name then
      table.remove(hosts, index)
      save()
      return notify("Removed " .. name)
    end
  end
  notify(name .. " is not a known host", vim.log.levels.WARN)
end

---@param host core.remote.Host
---@param dir string
---@return boolean
function M.register(host, dir)
  load()
  if vim.list_contains(host.projects, dir) then
    notify(dir .. " is already a project on " .. host.name)
    return false
  end
  table.insert(host.projects, 1, dir)
  save()
  notify(("Registered %s on %s"):format(dir, host.name))
  return true
end

-- Quick edit is remembered apart from the projects: the folder a file happens to
-- sit in is not a project, and registering it would fill the list with noise.
---@param host core.remote.Host
---@param dir string
function M.browsed(host, dir)
  load()
  host.browsed = dir
  save()
end

---@param host core.remote.Host
---@param dir string
function M.remember(host, dir)
  load()
  host.last = dir
  if not vim.list_contains(host.projects, dir) then table.insert(host.projects, 1, dir) end
  save()
end

---@param host core.remote.Host
---@param dir string
function M.forget(host, dir)
  load()
  for index, project in ipairs(host.projects) do
    if project == dir then
      table.remove(host.projects, index)
      break
    end
  end
  if host.last == dir then host.last = host.projects[1] end
  save()
end

-- Only a plain alias is offered: a pattern or a negation is a rule about other
-- hosts rather than a host you can connect to.
---@return string[]
function M.from_ssh_config()
  local path = vim.fs.joinpath(assert(vim.uv.os_homedir()), ".ssh", "config")
  if vim.fn.filereadable(path) ~= 1 then return {} end
  local aliases = {}
  for _, line in ipairs(vim.fn.readfile(path)) do
    local value = line:match "^%s*[Hh][Oo][Ss][Tt]%s+(.+)$"
    for alias in (value or ""):gmatch "%S+" do
      if not alias:find "[*?!]" then aliases[#aliases + 1] = alias end
    end
  end
  table.sort(aliases)
  return aliases
end

local TYPE = {}

---@param on_added? fun(host: core.remote.Host)
function M.pick_add(on_added)
  local known = {}
  for _, host in ipairs(M.all()) do
    known[host.dest] = true
  end
  local items = { TYPE }
  for _, alias in ipairs(M.from_ssh_config()) do
    if not known[alias] then items[#items + 1] = alias end
  end

  local function finish(dest)
    local host = M.add(dest)
    if host and on_added then on_added(host) end
  end

  vim.ui.select(items, {
    prompt = "Add a server",
    format_item = function(item) return item == TYPE and "Type a destination…" or item .. "  (~/.ssh/config)" end,
  }, function(choice)
    if not choice then return end
    if choice ~= TYPE then return finish(choice) end
    vim.ui.input({ prompt = "Destination (user@host): " }, function(input)
      if input and vim.trim(input) ~= "" then finish(input) end
    end)
  end)
end

local ADD = {}

---@param prompt string
---@param on_choice fun(host: core.remote.Host)
function M.pick(prompt, on_choice)
  local items = vim.list_extend({}, M.all())
  items[#items + 1] = ADD
  vim.ui.select(items, {
    prompt = prompt,
    format_item = function(item)
      if item == ADD then return "Add a server…" end
      local detail = item.name == item.dest and "" or "  " .. item.dest
      return item.name .. detail
    end,
  }, function(choice)
    if not choice then return end
    if choice == ADD then return M.pick_add(on_choice) end
    on_choice(choice)
  end)
end

return M
