local M = {}

---@class assistant.Agent
---@field id string
---@field name string
---@field cmd string[]
---@field continue string[]
---@field resume string[]
---@field env? fun(): table<string, string>?
---@field mention fun(path: string, first?: integer, last?: integer): string
---@field resume_id fun(id: string): string[]
---@field new_id? fun(id: string): string[]
---@field sessions fun(cwd: string, since: integer): assistant.Session[] newest first
---@field has_session fun(cwd: string, id: string): boolean

---@class assistant.Session
---@field id string
---@field mtime integer

---@class assistant.Instance
---@field agent assistant.Agent
---@field number integer
---@field bufnr integer
---@field job integer
---@field cwd string
---@field started integer
---@field session? string
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

---@return string
local function uuid()
  local bytes = { vim.uv.random(16):byte(1, 16) }
  bytes[7] = bit.bor(bit.band(bytes[7], 0x0f), 0x40)
  bytes[9] = bit.bor(bit.band(bytes[9], 0x3f), 0x80)
  local hex = table.concat(vim.tbl_map(function(byte) return ("%02x"):format(byte) end, bytes))
  return ("%s-%s-%s-%s-%s"):format(hex:sub(1, 8), hex:sub(9, 12), hex:sub(13, 16), hex:sub(17, 20), hex:sub(21))
end

---@param a assistant.Session
---@param b assistant.Session
local function newest_first(a, b) return a.mtime > b.mtime end

---@param cwd string
---@return string
local function claude_project(cwd)
  local home = vim.env.CLAUDE_CONFIG_DIR or vim.fs.joinpath(assert(vim.uv.os_homedir()), ".claude")
  return vim.fs.joinpath(home, "projects", (cwd:gsub("[^%w]", "-")))
end

---@param cwd string
---@param since integer
---@return assistant.Session[]
local function claude_sessions(cwd, since)
  local found = {}
  local directory = claude_project(cwd)
  for name, kind in vim.fs.dir(directory) do
    local id = kind == "file" and name:match "^(.+)%.jsonl$"
    local stat = id and vim.uv.fs_stat(vim.fs.joinpath(directory, name))
    if stat and stat.mtime.sec >= since then found[#found + 1] = { id = id, mtime = stat.mtime.sec } end
  end
  table.sort(found, newest_first)
  return found
end

---@param path string
---@return string?
local function first_line(path)
  local file = io.open(path, "r")
  if not file then return nil end
  local line = file:read "*l"
  file:close()
  return line
end

---@return string
local function codex_home() return vim.env.CODEX_HOME or vim.fs.joinpath(assert(vim.uv.os_homedir()), ".codex") end

-- Codex files its sessions by local date and names no cwd in the path, so the
-- days since `since` are walked and each file's first line is asked.
---@param cwd string
---@param since integer
---@return assistant.Session[]
local function codex_sessions(cwd, since)
  local home = codex_home()
  local found = {}
  local day = since
  while day <= os.time() + 86400 do
    local directory = vim.fs.joinpath(home, "sessions", os.date("%Y/%m/%d", day) --[[@as string]])
    for name, kind in vim.fs.dir(directory) do
      local id = kind == "file" and name:match "^rollout%-.*%-(%x+%-%x+%-%x+%-%x+%-%x+)%.jsonl$"
      local path = vim.fs.joinpath(directory, name)
      local stat = id and vim.uv.fs_stat(path)
      if stat and stat.mtime.sec >= since then
        local ok, meta = pcall(vim.json.decode, first_line(path) or "")
        if ok and type(meta) == "table" and type(meta.payload) == "table" and meta.payload.cwd == cwd then
          found[#found + 1] = { id = id, mtime = stat.mtime.sec }
        end
      end
    end
    day = day + 86400
  end
  table.sort(found, newest_first)
  return found
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
    resume_id = function(id) return { "--resume", id } end,
    new_id = function(id) return { "--session-id", id } end,
    sessions = claude_sessions,
    has_session = function(cwd, id) return vim.uv.fs_stat(vim.fs.joinpath(claude_project(cwd), id .. ".jsonl")) ~= nil end,
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
    resume_id = function(id) return { "resume", id } end,
    sessions = codex_sessions,
    has_session = function(_, id)
      return #vim.fn.glob(vim.fs.joinpath(codex_home(), "sessions", "*", "*", "*", "rollout-*-" .. id .. ".jsonl"), false, true) > 0
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
local function drop(instance)
  for i, other in ipairs(instances) do
    if other == instance then
      table.remove(instances, i)
      break
    end
  end
  if current == instance then current = instances[#instances] end
end

---@param instance assistant.Instance
local function forget(instance)
  drop(instance)
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
---@param session? string
---@param cwd string
---@return string[] args, string? session
local function session_args(agent, mode, session, cwd)
  if session then return agent.resume_id(session), session end
  if mode == "continue" then
    return agent.continue, agent.new_id and (agent.sessions(cwd, 0)[1] or {}).id or nil
  end
  if mode == "resume" then return agent.resume, nil end
  if not agent.new_id then return {}, nil end
  local id = uuid()
  return agent.new_id(id), id
end

---@param agent assistant.Agent
---@param mode? "continue"|"resume"
---@param opts? { cwd?: string, session?: string, number?: integer, hidden?: boolean }
---@return assistant.Instance?
function M.start(agent, mode, opts)
  opts = opts or {}
  if vim.fn.executable(agent.cmd[1]) ~= 1 then
    notify(("%s is not on PATH"):format(agent.cmd[1]), vim.log.levels.WARN)
    return nil
  end
  local cwd = opts.cwd or vim.fs.normalize(vim.fn.getcwd())
  local args, session = session_args(agent, mode, opts.session, cwd)
  local argv = vim.list_extend(vim.list_extend(vim.list_slice(agent.cmd), args), add_dirs(cwd))
  local instance = {
    agent = agent,
    number = opts.number or next_number(agent),
    bufnr = vim.api.nvim_create_buf(false, true),
    cwd = cwd,
    started = os.time(),
    session = session,
    job = 0,
  }
  instances[#instances + 1] = instance
  if opts.hidden then
    current = instance
  else
    show(instance, true)
  end
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
  -- A key pressed in a terminal whose process has exited deletes the buffer.
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    buffer = instance.bufnr,
    once = true,
    callback = function() drop(instance) end,
  })
  return instance
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
  for _, instance in ipairs(vim.list_slice(instances)) do
    if not vim.api.nvim_buf_is_valid(instance.bufnr) then drop(instance) end
  end
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

-- An instance knows its conversation only when it chose one: a new Claude is
-- given its id, and a Resume picked inside the agent is found afterwards as the
-- newest conversation in its cwd that no other instance has claimed.
---@return table<assistant.Instance, string>
local function conversations()
  local claimed, found = {}, {}
  local live = vim.tbl_filter(function(instance) return not instance.exited end, instances)
  for _, instance in ipairs(live) do
    if instance.session and instance.agent.has_session(instance.cwd, instance.session) then
      claimed[instance.session], found[instance] = true, instance.session
    end
  end
  for _, instance in ipairs(live) do
    if not found[instance] then
      for _, session in ipairs(instance.agent.sessions(instance.cwd, instance.started - 2)) do
        if not claimed[session.id] then
          claimed[session.id], found[instance] = true, session.id
          break
        end
      end
    end
  end
  return found
end

---@return table?
function M.snapshot()
  local found = conversations()
  local saved = {}
  for _, instance in ipairs(instances) do
    if not instance.exited then
      saved[#saved + 1] = {
        agent = instance.agent.id,
        number = instance.number,
        cwd = instance.cwd,
        session = found[instance],
        current = instance == current or nil,
      }
    end
  end
  if #saved == 0 then return nil end
  local win = panel_win()
  return { instances = saved, panel = win ~= nil, width = win and vim.api.nvim_win_get_width(win) }
end

---@param data table
function M.restore(data)
  if #instances > 0 or type(data.instances) ~= "table" then return end
  local by_id = {}
  for _, agent in ipairs(M.AGENTS) do
    by_id[agent.id] = agent
  end
  local chosen
  for _, saved in ipairs(data.instances) do
    local agent = by_id[saved.agent]
    local cwd = type(saved.cwd) == "string" and vim.fn.isdirectory(saved.cwd) == 1 and saved.cwd or nil
    if agent and cwd then
      local session = saved.session and agent.has_session(cwd, saved.session) and saved.session or nil
      local instance = M.start(agent, nil, { cwd = cwd, session = session, number = saved.number, hidden = true })
      if instance and saved.current then chosen = instance end
    end
  end
  current = chosen or current
  if not data.panel or not current then return end
  local return_to = vim.api.nvim_get_current_win()
  show(current, false)
  local win = panel_win()
  if win and data.width then vim.api.nvim_win_set_width(win, data.width) end
  if vim.api.nvim_win_is_valid(return_to) then vim.api.nvim_set_current_win(return_to) end
end

return M
