local M = {}

local hosts = require "core.remote.hosts"

---@param message string
---@param level? integer
local function notify(message, level) vim.notify(message, level or vim.log.levels.INFO, { title = "Remote" }) end

---@return string
local function repository_script()
  return [[
cd "$HOME" 2>/dev/null || exit 1
if command -v fd >/dev/null 2>&1; then
  fd --hidden --no-ignore --type d --max-depth 5 --prune '^\.git$' . | sed 's#/\.git/*$##'
else
  find . -maxdepth 5 -type d -name .git -prune 2>/dev/null | sed 's#/\.git$##'
fi
]]
end

---@param host core.remote.Host
---@param on_choice fun(dir: string)
local function pick_repository(host, on_choice)
  local ssh = require "core.remote.ssh"
  notify("Looking for repositories on " .. host.name)
  ssh.script(host.dest, repository_script(), function(lines, failure)
    if failure then return notify(("Could not search %s: %s"):format(host.name, failure), vim.log.levels.ERROR) end
    local found = {}
    for _, line in ipairs(lines) do
      local path = vim.trim(line):gsub("^%./", "")
      if path ~= "" and path ~= "." then found[#found + 1] = path end
    end
    if #found == 0 then return notify("No git repositories found under the home directory on " .. host.name) end
    table.sort(found)
    vim.ui.select(found, { prompt = "Repository on " .. host.name }, function(choice)
      if choice then on_choice("~/" .. choice) end
    end)
  end)
end

local BROWSE, FIND, TYPE = {}, {}, {}

---@param host core.remote.Host
---@param opts { prompt: string, known: string[], on_choice: fun(dir: string) }
local function locate(host, opts)
  local items = vim.list_extend({}, opts.known)
  items[#items + 1] = BROWSE
  items[#items + 1] = FIND
  items[#items + 1] = TYPE

  vim.ui.select(items, {
    prompt = opts.prompt,
    format_item = function(item)
      if item == BROWSE then return "Browse the server…" end
      if item == FIND then return "Find a git repository…" end
      if item == TYPE then return "Type a path…" end
      return "󰊠 " .. item .. (item == host.last and "  (last)" or "")
    end,
  }, function(choice)
    if not choice then return end
    if choice == BROWSE then
      return require("core.remote.browse").start { host = host, kind = "dir", on_choice = opts.on_choice }
    end
    if choice == FIND then
      return require("core.remote.ssh").connect(host.dest, function(ok, err)
        if not ok then return notify(err or "could not connect", vim.log.levels.ERROR) end
        pick_repository(host, opts.on_choice)
      end)
    end
    if choice == TYPE then
      return vim.ui.input({ prompt = "Path on " .. host.name .. ": ", default = host.last }, function(input)
        if input and vim.trim(input) ~= "" then opts.on_choice(vim.trim(input)) end
      end)
    end
    opts.on_choice(choice)
  end)
end

---@param host core.remote.Host
function M.pick_project(host)
  locate(host, {
    prompt = "Open a project on " .. host.name,
    known = host.projects,
    on_choice = function(dir) require("core.remote.connect").open(host, dir) end,
  })
end

---@param host core.remote.Host
function M.register_project(host)
  locate(host, {
    prompt = "Register a project on " .. host.name,
    known = {},
    on_choice = function(dir) hosts.register(host, dir) end,
  })
end

local PROJECT, FILE, REGISTER, SETUP, FORGET, DROP = {}, {}, {}, {}, {}, {}

---@param host core.remote.Host
function M.menu(host)
  local items = { PROJECT, FILE }
  vim.list_extend(items, host.projects)
  items[#items + 1] = REGISTER
  items[#items + 1] = SETUP
  items[#items + 1] = FORGET
  items[#items + 1] = DROP

  vim.ui.select(items, {
    prompt = host.name,
    format_item = function(item)
      if item == PROJECT then return "Open a project…  (the full editor, over a tunnel)" end
      if item == FILE then return "Open a file…  (edit one file over scp)" end
      if item == REGISTER then return "Register a project…" end
      if item == SETUP then return "Install or update the config on " .. host.name end
      if item == FORGET then return "Forget a project…" end
      if item == DROP then return "Remove " .. host.name end
      return "󰊠 " .. item
    end,
  }, function(choice)
    if not choice then return end
    if choice == PROJECT then return M.pick_project(host) end
    if choice == FILE then return require("core.remote.files").open(host) end
    if choice == REGISTER then return M.register_project(host) end
    if choice == SETUP then return require("core.remote.install").run(host) end
    if choice == DROP then return hosts.remove(host.name) end
    if choice == FORGET then
      if #host.projects == 0 then return notify("No projects are remembered for " .. host.name) end
      return vim.ui.select(host.projects, { prompt = "Forget a project on " .. host.name }, function(project)
        if project then
          hosts.forget(host, project)
          notify("Forgot " .. project)
        end
      end)
    end
    require("core.remote.connect").open(host, choice)
  end)
end

local ADD_HOST = {}

function M.pick()
  local all = hosts.all()
  if #all == 0 then return hosts.pick_add(M.menu) end

  local items = {}
  for _, host in ipairs(all) do
    items[#items + 1] = host
    for _, project in ipairs(host.projects) do
      items[#items + 1] = { host = host, dir = project }
    end
  end
  items[#items + 1] = ADD_HOST

  vim.ui.select(items, {
    prompt = "Servers",
    format_item = function(item)
      if item == ADD_HOST then return "Add a server…" end
      if item.dir then return ("    󰊠 %s  (%s)"):format(item.dir, item.host.name) end
      return item.name .. (item.name == item.dest and "" or "  " .. item.dest)
    end,
  }, function(choice)
    if not choice then return end
    if choice == ADD_HOST then return hosts.pick_add(M.menu) end
    if choice.dir then return require("core.remote.connect").open(choice.host, choice.dir) end
    M.menu(choice)
  end)
end

function M.pick_open() hosts.pick("Open a project on", M.pick_project) end

function M.pick_disconnect()
  local connect = require "core.remote.connect"
  local sessions = connect.sessions()
  if #sessions == 0 then
    local active = require("core.remote.ssh").active()
    if #active == 0 then return notify "Nothing is connected" end
    return vim.ui.select(active, { prompt = "Disconnect from" }, function(dest)
      if dest then
        require("core.remote.ssh").disconnect(dest)
        notify("Disconnected from " .. dest)
      end
    end)
  end
  vim.ui.select(sessions, {
    prompt = "Remote editors",
    format_item = function(session) return ("%s:%s"):format(session.host.name, session.dir) end,
  }, function(session)
    if not session then return end
    vim.ui.select({ false, true }, {
      prompt = ("%s:%s"):format(session.host.name, session.dir),
      format_item = function(stop)
        if stop then return "Stop the editor on the server" end
        return "Detach, and leave it running there"
      end,
    }, function(stop)
      if stop ~= nil then connect.close(session, stop) end
    end)
  end)
end

---@return core.ActionProvider
local function provider()
  return {
    id = "remote",
    name = "Remote",
    priority = 10,
    detect = function()
      local count = #hosts.all()
      if count == 0 then return "no servers added yet" end
      return ("%d server%s"):format(count, count == 1 and "" or "s")
    end,
    actions = function()
      return {
        {
          id = "project",
          label = "Open a project on a server",
          category = "Open",
          repeatable = false,
          available = function() return #hosts.all() > 0 or "no servers added yet -- add one with <Leader>oa" end,
          run = M.pick_open,
        },
        {
          id = "file",
          label = "Open a single file on a server",
          detail = "over scp, with no setup on the server",
          category = "Open",
          repeatable = false,
          available = function() return #hosts.all() > 0 or "no servers added yet -- add one with <Leader>oa" end,
          run = function() require("core.remote.files").pick() end,
        },
        {
          id = "add",
          label = "Add a server",
          category = "Maintenance",
          repeatable = false,
          run = function() hosts.pick_add(M.menu) end,
        },
        {
          id = "install",
          label = "Install this config on a server",
          category = "Maintenance",
          repeatable = false,
          available = function() return #hosts.all() > 0 or "no servers added yet -- add one with <Leader>oa" end,
          run = function() require("core.remote.install").pick() end,
        },
        {
          id = "disconnect",
          label = "Disconnect from a server",
          category = "Maintenance",
          repeatable = false,
          run = M.pick_disconnect,
        },
      }
    end,
    status = function()
      local lines = {}
      for _, host in ipairs(hosts.all()) do
        local connected = require("core.remote.ssh").connected(host.dest)
        lines[#lines + 1] = ("%s (%s): %s, %d project%s"):format(
          host.name,
          host.dest,
          connected and "connected" or "not connected",
          #host.projects,
          #host.projects == 1 and "" or "s"
        )
      end
      for _, session in ipairs(require("core.remote.connect").sessions()) do
        lines[#lines + 1] = ("editor on %s:%s via %s"):format(session.host.name, session.dir, session.socket)
      end
      return lines
    end,
  }
end

function M.setup()
  local ssh = require "core.remote.ssh"
  -- netrw runs its own ssh and scp, so they are pointed at the same control
  -- socket: one authentication serves browsing, editing and the tunnel.
  vim.g.netrw_ssh_cmd = "ssh -o ControlMaster=auto -o ControlPath=" .. ssh.control_path()
  vim.g.netrw_scp_cmd = "scp -q -o ControlMaster=auto -o ControlPath=" .. ssh.control_path()

  require("core.actions").register(provider())

  vim.api.nvim_create_user_command("Remote", M.pick, { desc = "Servers" })
  vim.api.nvim_create_user_command("RemoteAdd", function(args)
    if args.args == "" then return hosts.pick_add(M.menu) end
    hosts.add(args.args)
  end, { nargs = "?", desc = "Add a server" })
  vim.api.nvim_create_user_command("RemoteOpen", M.pick_open, { desc = "Open a project on a server" })
  vim.api.nvim_create_user_command(
    "RemoteFile",
    function() require("core.remote.files").pick() end,
    { desc = "Open a single file on a server over scp" }
  )
  vim.api.nvim_create_user_command(
    "RemoteInstall",
    function() require("core.remote.install").pick() end,
    { desc = "Install this config on a server" }
  )
  vim.api.nvim_create_user_command("RemoteDisconnect", M.pick_disconnect, { desc = "Disconnect from a server" })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("core_remote", { clear = true }),
    desc = "Tear down ssh tunnels and control connections",
    callback = function() require("core.remote.connect").shutdown() end,
  })
end

return M
