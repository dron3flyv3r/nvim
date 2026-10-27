local M = {}

---@class assistant.Agent
---@field id string
---@field name string
---@field cmd string[]
---@field continue string[]
---@field resume string[]
---@field env? fun(): table<string, string>?
---@field mention fun(path: string, first?: integer, last?: integer): string

---@class assistant.Instance
---@field agent assistant.Agent
---@field number integer
---@field bufnr integer
---@field job integer
---@field cwd string
---@field exited? integer

local WIDTH = 0.30
local PASTE_START, PASTE_END = "\27[200~", "\27[201~"

---@param hosts string?
---@return string
local function with_loopback(hosts)
  local list = vim.tbl_filter(function(host) return host ~= "" end, vim.split(hosts or "", ",", { trimempty = true }))
  for _, host in ipairs { "localhost", "127.0.0.1", "::1" } do
    if not vim.list_contains(list, host) then list[#list + 1] = host end
  end
  return table.concat(list, ",")
end

-- The CLI connects back to claudecode's websocket server for the selection, @
-- mentions and the diffs; that server is shared by every Claude instance.
---@return table<string, string>?
local function claude_env()
  local ok, claudecode = pcall(require, "claudecode")
  if not ok then return nil end
  if not claudecode.state.port then claudecode.start(false) end
  local port = claudecode.state.port
  if not port then return nil end
  local no_proxy = with_loopback(vim.env.no_proxy or vim.env.NO_PROXY)
  return {
    CLAUDE_CODE_SSE_PORT = tostring(port),
    ENABLE_IDE_INTEGRATION = "true",
    FORCE_CODE_TERMINAL = "true",
    no_proxy = no_proxy,
    NO_PROXY = no_proxy,
  }
end

---@type assistant.Agent[]
M.AGENTS = {
  {
    id = "claude",
    name = "Claude",
    cmd = { "claude" },
    continue = { "--continue" },
    resume = { "--resume" },
    env = claude_env,
    mention = function(path, first, last)
      if not first then return "@" .. path end
      return ("@%s#L%d-%d"):format(path, first, last)
    end,
  },
  {
    id = "codex",
    name = "Codex",
    cmd = { "codex" },
    continue = { "resume", "--last" },
    resume = { "resume" },
    mention = function(path, first, last)
      if not first then return "@" .. path end
      return ("@%s (lines %d-%d)"):format(path, first, last)
    end,
  },
}

---@type assistant.Instance[]
local instances = {}
---@type assistant.Instance?
local current

local function notify(message, level) vim.notify(message, level or vim.log.levels.INFO, { title = "Agents" }) end

---@param instance assistant.Instance
---@return string
local function title(instance) return ("%s %d"):format(instance.agent.name, instance.number) end

---@return integer?
local function panel_win()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.w[win].assistant_panel then return win end
  end
end

---@param win integer
local function dress(win)
  local others = #instances - 1
  local label = current and title(current) or ""
  if others > 0 then label = ("%s  ·  %d more on <Leader>aa"):format(label, others) end
  vim.wo[win].winbar = " " .. label:gsub("%%", "%%%%")
end

---@param instance assistant.Instance
local function forget(instance)
  for i, other in ipairs(instances) do
    if other == instance then
      table.remove(instances, i)
      break
    end
  end
  if current == instance then current = instances[#instances] end
  local win = panel_win()
  if win and current and vim.api.nvim_win_get_buf(win) == instance.bufnr then
    vim.api.nvim_win_set_buf(win, current.bufnr)
    dress(win)
  end
  if vim.api.nvim_buf_is_valid(instance.bufnr) then pcall(vim.api.nvim_buf_delete, instance.bufnr, { force = true }) end
end

local function forget_exited(except)
  for _, instance in ipairs(vim.list_slice(instances)) do
    if instance.exited and instance ~= except then forget(instance) end
  end
end

---@param instance assistant.Instance
---@param focus boolean
local function show(instance, focus)
  current = instance
  forget_exited(instance)
  local win = panel_win()
  if win then
    vim.api.nvim_win_set_buf(win, instance.bufnr)
    if focus then vim.api.nvim_set_current_win(win) end
  else
    win = vim.api.nvim_open_win(instance.bufnr, focus, {
      split = "right",
      win = -1,
      width = math.floor(vim.o.columns * WIDTH),
    })
    vim.w[win].assistant_panel = true
    vim.wo[win].winfixwidth = true
  end
  dress(win)
  if focus and not instance.exited then vim.cmd.startinsert() end
end

local function hide()
  local win = panel_win()
  if win and #vim.api.nvim_tabpage_list_wins(0) > 1 then vim.api.nvim_win_close(win, false) end
end

---@param agent assistant.Agent
---@return integer
local function next_number(agent)
  local highest = 0
  for _, instance in ipairs(instances) do
    if instance.agent == agent then highest = math.max(highest, instance.number) end
  end
  return highest + 1
end

---@param cwd string
---@return string[]
local function add_dirs(cwd)
  local dirs = require("core.workspace").dirs() or {}
  local args = {}
  for _, dir in ipairs(dirs) do
    if dir ~= cwd then vim.list_extend(args, { "--add-dir", dir }) end
  end
  return args
end

---@param agent assistant.Agent
---@param mode? "continue"|"resume"
function M.start(agent, mode)
  if vim.fn.executable(agent.cmd[1]) ~= 1 then
    return notify(("%s is not on PATH"):format(agent.cmd[1]), vim.log.levels.WARN)
  end
  local cwd = vim.fs.normalize(vim.fn.getcwd())
  local argv = vim.list_extend(vim.list_extend(vim.list_slice(agent.cmd), mode and agent[mode] or {}), add_dirs(cwd))
  local instance = {
    agent = agent,
    number = next_number(agent),
    bufnr = vim.api.nvim_create_buf(false, true),
    cwd = cwd,
    job = 0,
  }
  instances[#instances + 1] = instance
  show(instance, true)
  vim.api.nvim_buf_call(instance.bufnr, function()
    instance.job = vim.fn.jobstart(argv, {
      term = true,
      cwd = cwd,
      env = agent.env and agent.env() or nil,
      on_exit = function(_, code)
        vim.schedule(function()
          if code == 0 then return forget(instance) end
          instance.exited = code
          notify(("%s exited with %d; <Leader>aa shows its output"):format(title(instance), code), vim.log.levels.WARN)
        end)
      end,
    })
  end)
  vim.api.nvim_buf_set_name(instance.bufnr, ("agent://%s/%d"):format(agent.id, instance.number))
  vim.api.nvim_create_autocmd("BufEnter", {
    buffer = instance.bufnr,
    callback = function() current = instance end,
  })
end

---@return assistant.Agent[]
local function installed()
  return vim.tbl_filter(function(agent) return vim.fn.executable(agent.cmd[1]) == 1 end, M.AGENTS)
end

---@param agent assistant.Agent
---@param mode? "continue"|"resume"
---@return { label: string, run: fun() }
local function start_item(agent, mode)
  local verb = mode == "continue" and "Continue the last" or mode == "resume" and "Resume a" or "New"
  return { label = ("%s %s session"):format(verb, agent.name), run = function() M.start(agent, mode) end }
end

function M.pick()
  local items = {}
  for i = #instances, 1, -1 do
    local instance = instances[i]
    local state = instance.exited and ("exited %d"):format(instance.exited) or vim.fn.fnamemodify(instance.cwd, ":~")
    items[#items + 1] = {
      label = ("%s%s  ·  %s"):format(title(instance), instance == current and " (current)" or "", state),
      run = function() show(instance, true) end,
    }
  end
  for _, agent in ipairs(installed()) do
    items[#items + 1] = start_item(agent)
  end
  for _, agent in ipairs(installed()) do
    items[#items + 1] = start_item(agent, "continue")
    items[#items + 1] = start_item(agent, "resume")
  end
  if #items == 0 then return notify("Neither claude nor codex is on PATH", vim.log.levels.WARN) end
  vim.ui.select(items, {
    prompt = "Agents",
    format_item = function(item) return item.label end,
  }, function(choice)
    if choice then choice.run() end
  end)
end

---@param mode "continue"|"resume"
function M.start_like_current(mode)
  local agent = current and current.agent or installed()[1]
  if not agent then return notify("Neither claude nor codex is on PATH", vim.log.levels.WARN) end
  M.start(agent, mode)
end

---@return assistant.Instance?
local function target()
  if current and not current.exited and vim.api.nvim_buf_is_valid(current.bufnr) then return current end
  for i = #instances, 1, -1 do
    if not instances[i].exited then return instances[i] end
  end
end

function M.focus()
  local win = panel_win()
  if win and win == vim.api.nvim_get_current_win() then return hide() end
  local instance = target() or current
  if not instance then return notify "No agent is open; <Leader>aa starts one" end
  show(instance, true)
end

---@param instance assistant.Instance
---@param path string
---@return string
local function relative(instance, path)
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  return vim.fs.relpath(instance.cwd, path) or path
end

---@param build fun(instance: assistant.Instance): string[]
local function send(build)
  local instance = target()
  if not instance then return notify "No agent is open; <Leader>aa starts one" end
  local mentions = build(instance)
  if #mentions == 0 then return notify "Nothing to send" end
  vim.api.nvim_chan_send(instance.job, PASTE_START .. table.concat(mentions, " ") .. " " .. PASTE_END)
  if not panel_win() then show(instance, false) end
  notify(("Sent %s to %s"):format(#mentions == 1 and mentions[1] or (#mentions .. " files"), title(instance)))
end

---@return string?
local function buffer_file()
  local bufnr = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(bufnr)
  if vim.bo[bufnr].buftype ~= "" or name == "" or name:find("://", 1, true) then return nil end
  return name
end

function M.add_buffer()
  local file = buffer_file()
  if not file then return notify("This buffer is not a file", vim.log.levels.WARN) end
  send(function(instance) return { instance.agent.mention(relative(instance, file)) } end)
end

---@return string[]
local function picker_selection()
  local ok, pickers = pcall(function() return Snacks.picker.get() end)
  if not ok then return {} end
  local win = vim.api.nvim_get_current_win()
  for _, picker in ipairs(pickers) do
    if picker.list and picker.list.win and picker.list.win.win == win then
      local paths = {}
      for _, item in ipairs(picker:selected { fallback = true }) do
        local path = Snacks.picker.util.path(item)
        if path then paths[#paths + 1] = path end
      end
      return paths
    end
  end
  return {}
end

function M.send()
  if vim.bo.filetype == "snacks_picker_list" then
    local paths = picker_selection()
    return send(function(instance)
      return vim.tbl_map(function(path) return instance.agent.mention(relative(instance, path)) end, paths)
    end)
  end
  local file = buffer_file()
  if not file then return notify("This buffer is not a file", vim.log.levels.WARN) end
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" then
    local first, last = vim.fn.line "v", vim.fn.line "."
    if first > last then
      first, last = last, first
    end
    vim.api.nvim_feedkeys(vim.keycode "<Esc>", "nx", false)
    return send(function(instance) return { instance.agent.mention(relative(instance, file), first, last) } end)
  end
  M.add_buffer()
end

return M
