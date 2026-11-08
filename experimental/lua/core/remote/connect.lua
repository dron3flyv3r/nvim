local M = {}

local ssh = require "core.remote.ssh"
local hosts = require "core.remote.hosts"

local APPNAME = "nvim/experimental"
local READY_INTERVAL_MS = 300
local READY_TIMEOUT_MS = 30000

---@class core.remote.Session
---@field host core.remote.Host
---@field dir string
---@field socket string the forwarded socket on this machine
---@field remote string the listening socket on the server
---@field tunnel integer the ssh -L job
---@field bufnr? integer the terminal this instance renders it in
---@field from_tab? integer the tabpage it was opened from

---@type table<string, core.remote.Session>
local sessions = {}

---@param message string
---@param level? integer
local function notify(message, level) vim.notify(message, level or vim.log.levels.INFO, { title = "Remote" }) end

---@param host core.remote.Host
---@param dir string
---@return string
local function key(host, dir) return host.name .. "\0" .. dir end

---@param dir string
---@return string
local function slug(dir) return vim.fn.sha256(dir):sub(1, 16) end

---@param host core.remote.Host
---@param dir string
---@return string
local function local_socket(host, dir)
  local base = vim.uv.os_getenv "XDG_RUNTIME_DIR"
  local parent = base and vim.fn.isdirectory(base) == 1 and base or vim.fn.stdpath "state" --[[@as string]]
  local directory = vim.fs.joinpath(parent, "nvim-remote")
  vim.fs.mkdir(directory, { parents = true })
  return vim.fs.joinpath(directory, ("%s-%s.sock"):format(slug(host.name), slug(dir)))
end

---@param dir string
---@return string
local function probe_script(dir)
  return ([[
NV="$HOME/.local/share/nvim-versions/current/bin/nvim"
[ -x "$NV" ] || NV="$(command -v nvim 2>/dev/null)"
[ -n "$NV" ] || { echo "NVIM none"; exit 0; }
echo "NVIM $NV"
echo "RUNTIME ${XDG_RUNTIME_DIR:-/tmp}/nvim-remote"
cd %s 2>/dev/null || { echo "DIR missing"; exit 0; }
echo "DIR $(pwd -P)"
]]):format(ssh.quote(dir))
end

-- setsid and a closed stdin, so the editor is not a child of the ssh that asked
-- for it: the session then survives this Neovim quitting and is reattached to.
---@param nvim string
---@param dir string
---@param socket string
---@return string
local function start_script(nvim, dir, socket)
  local parts = {
    nvim = vim.fn.shellescape(nvim),
    dir = ssh.quote(dir),
    sock = vim.fn.shellescape(socket),
    app = APPNAME,
  }
  return (
    ([[
mkdir -p "$(dirname ${sock})" 2>/dev/null
if [ -S ${sock} ] && ${nvim} --server ${sock} --remote-expr "1" >/dev/null 2>&1; then echo LIVE; exit 0; fi
cd ${dir} || exit 1
rm -f ${sock}
NVIM_APPNAME=${app} setsid nohup ${nvim} --headless --listen ${sock} >/dev/null 2>&1 </dev/null &
echo STARTED
]]):gsub("%${(%w+)}", parts)
  )
end

---@param socket string
---@return boolean
local function reachable(socket)
  if not vim.uv.fs_stat(socket) then return false end
  local cmd = { vim.v.progpath, "--server", socket, "--remote-expr", "1" }
  return vim.system(cmd, { text = true }):wait(3000).code == 0
end

-- Every key belongs to the editor on the server, so the terminal-mode mappings
-- this config installs are sent through on this buffer alone. <Esc> is the one
-- that matters: the global <Esc><Esc> would hold every single press for
-- timeoutlen, and a nested editor needs Escape on the first press.
local PASSED_THROUGH =
  { "<Esc>", "<C-h>", "<C-j>", "<C-k>", "<C-l>", "<C-Up>", "<C-Down>", "<C-Left>", "<C-Right>", "j", "k" }

---@param session core.remote.Session
local function claim_keys(session)
  local bufnr = assert(session.bufnr)
  for _, lhs in ipairs(PASSED_THROUGH) do
    -- nowait, or <Esc> still waits out timeoutlen for the global <Esc><Esc>
    -- before it is sent, which is a second of nothing on the key a nested editor
    -- is driven by. It applies to buffer-local mappings only, which these are.
    vim.keymap.set("t", lhs, lhs, { buffer = bufnr, nowait = true, desc = "Send " .. lhs .. " to the remote editor" })
  end
  -- <C-\><C-n> is the native way out and still works, but a Danish layout needs
  -- AltGr for it, and nothing in this config or the remote's claims <C-q>.
  vim.keymap.set("t", "<C-q>", function()
    vim.cmd.stopinsert()
    if session.from_tab and vim.api.nvim_tabpage_is_valid(session.from_tab) then
      vim.api.nvim_set_current_tabpage(session.from_tab)
    end
  end, { buffer = bufnr, desc = "Leave the remote editor" })
end

---@param session core.remote.Session
local function forget(session)
  local slot = key(session.host, session.dir)
  if sessions[slot] ~= session then return end
  sessions[slot] = nil
  pcall(vim.fn.jobstop, session.tunnel)
  os.remove(session.socket)
end

-- laststatus is 3, so the one statusline this editor draws sits under a window
-- that already has a whole editor's own statusline in it. Giving the row back
-- while the client is the current window is what makes the remote editor look
-- like a local one; the tabline is left alone, because the git review owns when
-- that row is shown.
local hidden = false
local statusline_was

local function dress()
  if vim.bo.buftype == "terminal" and vim.b.core_remote ~= nil then
    if not hidden then
      statusline_was, hidden = vim.o.laststatus, true
    end
    -- Re-asserted rather than set once: the dashboard hides this row too and
    -- puts it back when it closes, which happens with no window event of ours.
    if vim.o.laststatus ~= 0 then vim.o.laststatus = 0 end
  elseif hidden then
    hidden = false
    -- Only the value we set is ours to put back; anything else is that writer's.
    if vim.o.laststatus == 0 then vim.o.laststatus = statusline_was end
  end
end

-- Deleting the buffer leaves its window showing something else, so the tab the
-- client had to itself stays behind empty. Closing the window is what takes the
-- tab with it -- unless it is the only window left, which would end the session.
---@param bufnr integer
local function close_client(bufnr)
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    local alone = #vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(win)) == 1
    if not (alone and #vim.api.nvim_list_tabpages() == 1) then pcall(vim.api.nvim_win_close, win, true) end
  end
  if vim.api.nvim_buf_is_valid(bufnr) then pcall(vim.api.nvim_buf_delete, bufnr, { force = true }) end
  vim.schedule(dress)
end

---@param session core.remote.Session
---@param code integer
local function client_exited(session, code)
  forget(session)
  if code == 0 then
    if session.bufnr then close_client(session.bufnr) end
    return notify(("Closed %s on %s"):format(vim.fn.fnamemodify(session.dir, ":~"), session.host.name))
  end
  notify(
    ("The connection to %s closed (exit %d) -- the terminal says why"):format(session.host.name, code),
    vim.log.levels.WARN
  )
end

-- The editor on the server is rendered by a UI client in a terminal of this
-- instance, in its own tabpage: --remote-ui sources no config and draws the
-- remote session whole, so a full tab is the window it wants.
---@param session core.remote.Session
local function launch(session)
  if session.bufnr and vim.api.nvim_buf_is_valid(session.bufnr) then
    local windows = vim.fn.win_findbuf(session.bufnr)
    if #windows > 0 then
      vim.api.nvim_set_current_win(windows[1])
      return vim.cmd.startinsert()
    end
  end

  session.from_tab = vim.api.nvim_get_current_tabpage()
  vim.cmd.tabnew()
  local bufnr = vim.api.nvim_get_current_buf()
  local job = vim.fn.jobstart({ vim.v.progpath, "--remote-ui", "--server", session.socket }, {
    term = true,
    on_exit = function(_, code)
      vim.schedule(function() client_exited(session, code) end)
    end,
  })
  if job <= 0 then
    vim.cmd.tabclose()
    return notify("Could not start the UI client for " .. session.host.name, vim.log.levels.ERROR)
  end

  session.bufnr = bufnr
  vim.b[bufnr].core_remote = ("%s:%s"):format(session.host.name, session.dir)
  local group = vim.api.nvim_create_augroup("core_remote_client", { clear = true })
  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter", "TabEnter", "WinClosed" }, {
    group = group,
    desc = "Give the statusline row to a remote editor",
    callback = vim.schedule_wrap(dress),
  })
  vim.api.nvim_create_autocmd("OptionSet", {
    group = group,
    pattern = "laststatus",
    desc = "Keep the statusline row with the remote editor",
    callback = dress,
  })
  pcall(vim.api.nvim_buf_set_name, bufnr, ("remote://%s%s"):format(session.host.name, session.dir))
  claim_keys(session)
  dress()
  vim.cmd.startinsert()
  notify(("Opened %s on %s -- <C-q> leaves it"):format(vim.fn.fnamemodify(session.dir, ":~"), session.host.name))
end

---@param session core.remote.Session
local function wait_and_launch(session)
  local elapsed = 0
  local timer = assert(vim.uv.new_timer())
  timer:start(
    READY_INTERVAL_MS,
    READY_INTERVAL_MS,
    vim.schedule_wrap(function()
      elapsed = elapsed + READY_INTERVAL_MS
      if reachable(session.socket) then
        timer:stop()
        timer:close()
        sessions[key(session.host, session.dir)] = session
        return launch(session)
      end
      if elapsed >= READY_TIMEOUT_MS then
        timer:stop()
        timer:close()
        pcall(vim.fn.jobstop, session.tunnel)
        notify("The remote editor did not come up within 30s on " .. session.host.name, vim.log.levels.ERROR)
      end
    end)
  )
end

---@param host core.remote.Host
---@param dir string
---@param remote string
local function forward(host, dir, remote)
  local socket = local_socket(host, dir)

  -- The client being alive is what makes this a reattach, not the tunnel: the
  -- window it is already in has to be found, or reopening the project orphans a
  -- tab holding a UI client nothing is tracking any more.
  local existing = sessions[key(host, dir)]
  if existing then
    local client = existing.bufnr
      and vim.api.nvim_buf_is_valid(existing.bufnr)
      and vim.b[existing.bufnr].terminal_job_id
    if client and vim.fn.jobwait({ client }, 0)[1] == -1 then return launch(existing) end
    forget(existing)
    if existing.bufnr then close_client(existing.bufnr) end
  end

  os.remove(socket)
  local tunnel = ssh.tunnel(host.dest, ("%s:%s"):format(socket, remote))
  if not tunnel then return notify("Could not forward the editor's socket", vim.log.levels.ERROR) end
  wait_and_launch { host = host, dir = dir, socket = socket, remote = remote, tunnel = tunnel }
end

---@param host core.remote.Host
---@param dir string
function M.open(host, dir)
  ssh.connect(host.dest, function(ok, err)
    if not ok then return notify(err or "could not connect to " .. host.name, vim.log.levels.ERROR) end
    ssh.script(host.dest, probe_script(dir), function(lines, failure)
      if failure then
        return notify(("Could not ask %s about Neovim: %s"):format(host.name, failure), vim.log.levels.ERROR)
      end

      local fields = {}
      for _, line in ipairs(lines) do
        local name, value = line:match "^(%u+) (.+)$"
        if name then fields[name] = value end
      end

      if fields.NVIM == "none" then
        return require("core.remote.install").offer(host, function() M.open(host, dir) end)
      end
      -- A probe that answered something else is a noisy login shell, not a server
      -- without Neovim, and offering the installer there teaches the wrong thing.
      if not fields.NVIM or not fields.RUNTIME then
        return notify(
          ("%s answered something unexpected: %s"):format(host.name, table.concat(lines, " ")),
          vim.log.levels.ERROR
        )
      end
      if not fields.DIR or fields.DIR == "missing" then
        hosts.forget(host, dir)
        return notify(dir .. " does not exist on " .. host.name, vim.log.levels.WARN)
      end

      -- The socket is named from the path the server resolved, so a project typed
      -- as ~/code and browsed to as /home/me/code is the one editor, not two.
      local resolved = fields.DIR
      if resolved ~= dir then hosts.forget(host, dir) end
      hosts.remember(host, resolved)

      local remote = ("%s/%s.sock"):format(fields.RUNTIME, slug(resolved))
      ssh.script(host.dest, start_script(fields.NVIM, resolved, remote), function(answer, why)
        local said = answer and vim.trim(answer[#answer] or "") or nil
        if said ~= "LIVE" and said ~= "STARTED" then
          return notify(
            ("Could not start the editor on %s: %s"):format(host.name, why or said or "no answer"),
            vim.log.levels.ERROR
          )
        end
        forward(host, resolved, remote)
      end)
    end)
  end)
end

---@return core.remote.Session[]
function M.sessions()
  local list = {}
  for _, session in pairs(sessions) do
    list[#list + 1] = session
  end
  table.sort(list, function(a, b) return a.host.name .. a.dir < b.host.name .. b.dir end)
  return list
end

---@param session core.remote.Session
---@param stop boolean whether to stop the editor on the server as well
function M.close(session, stop)
  forget(session)
  if session.bufnr then close_client(session.bufnr) end
  if not stop then return notify("Detached from " .. session.host.name .. " -- the editor is still running there") end
  local script = ([[
NV="$HOME/.local/share/nvim-versions/current/bin/nvim"
[ -x "$NV" ] || NV="$(command -v nvim 2>/dev/null)"
[ -n "$NV" ] && "$NV" --server %s --remote-send '<C-\><C-N>:qall!<CR>' >/dev/null 2>&1
rm -f %s
echo STOPPED
]]):format(vim.fn.shellescape(session.remote), vim.fn.shellescape(session.remote))
  ssh.script(session.host.dest, script, function() notify("Stopped the editor on " .. session.host.name) end)
end

function M.shutdown()
  for _, session in pairs(sessions) do
    pcall(vim.fn.jobstop, session.tunnel)
    os.remove(session.socket)
  end
  sessions = {}
  for _, dest in ipairs(ssh.active()) do
    ssh.disconnect(dest)
  end
end

return M
