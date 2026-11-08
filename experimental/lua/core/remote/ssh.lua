local M = {}

local CHECK_INTERVAL_MS = 400
local REVEAL_AFTER_MS = 1500
local CONNECT_TIMEOUT_MS = 120000

---@type table<string, { bufnr: integer, name: string, revealed: boolean, waiting: fun(ok: boolean, err?: string)[] }>
local masters = {}

---@return string
local function control_dir()
  local runtime = vim.uv.os_getenv "XDG_RUNTIME_DIR"
  local base = runtime and vim.fn.isdirectory(runtime) == 1 and runtime or vim.fn.stdpath "state" --[[@as string]]
  local dir = vim.fs.joinpath(base, "nvim-remote")
  vim.fs.mkdir(dir, { parents = true })
  return dir
end

-- %C hashes the connection parameters, so one pattern serves every host and the
-- path stays short enough for the 108-byte limit on a unix socket.
---@return string
function M.control_path() return vim.fs.joinpath(control_dir(), "%C") end

---@return string[]
function M.options()
  return {
    "-o",
    "ControlMaster=auto",
    "-o",
    "ControlPath=" .. M.control_path(),
    "-o",
    "ControlPersist=600",
  }
end

---@param dest string
---@param argv? string[]
---@return string[]
function M.cmd(dest, argv)
  local cmd = { "ssh" }
  vim.list_extend(cmd, M.options())
  cmd[#cmd + 1] = dest
  if argv and #argv > 0 then vim.list_extend(cmd, argv) end
  return cmd
end

---@param dest string
---@return boolean
function M.connected(dest)
  local cmd = { "ssh", "-o", "ControlPath=" .. M.control_path(), "-O", "check", dest }
  return vim.system(cmd, { text = true }):wait(3000).code == 0
end

-- shellescape single-quotes the whole path, and a tilde inside quotes is a
-- literal directory named ~, so a typed ~/code is resolved against $HOME here.
---@param path string
---@return string
function M.quote(path)
  if path == "~" then return '"$HOME"' end
  local rest = path:match "^~/(.*)$"
  if rest then return '"$HOME"/' .. vim.fn.shellescape(rest) end
  return vim.fn.shellescape(path)
end

-- ssh joins the command it is given with spaces and hands the result to the
-- remote login shell, so the script is single-quoted to survive that one split.
-- It was base64'd through a pipe into sh before, which needed a decoder the
-- server may not have: a missing one left sh reading an empty pipe, and sh with
-- nothing to read exits 0 with no output, so every caller read silence as
-- success -- an installer that installed nothing, and a probe that reported no
-- Neovim. Nothing but a login shell is needed now.
---@param script string
---@return string[]
function M.script_argv(script) return { "sh", "-c", vim.fn.shellescape(script) } end

local MARK = "__nvim_remote_reply__"

-- The reply is framed, and only what follows the mark is the script's: a login
-- shell that prints a banner or a motd on stdout otherwise hands over its first
-- line as the answer, and a server that ran nothing at all answers silently with
-- a zero exit status. Both were read as success.
---@param dest string
---@param script string
---@param on_done fun(lines: string[]|nil, failure: string?)
function M.script(dest, script, on_done)
  local framed = ("printf '%s\n'\n%s"):format(MARK, script)
  local cmd = M.cmd(dest, M.script_argv(framed))
  table.insert(cmd, 2, "-o")
  table.insert(cmd, 3, "BatchMode=yes")
  vim.system(cmd, { text = true }, function(result)
    vim.schedule(function()
      local stdout = result.stdout or ""
      local _, marked = stdout:find(MARK .. "\n", 1, true)
      if marked then return on_done(vim.split(stdout:sub(marked + 1), "\n", { trimempty = true }), nil) end
      local said = vim.trim(result.stderr or "")
      if said == "" then said = vim.trim(stdout) end
      if said == "" then said = ("it answered nothing, with exit status %d"):format(result.code) end
      on_done(nil, said)
    end)
  end)
end

---@param master { bufnr: integer }
---@return boolean
local function alive(master)
  if not vim.api.nvim_buf_is_valid(master.bufnr) then return false end
  local job = vim.b[master.bufnr].terminal_job_id
  return job ~= nil and vim.fn.jobwait({ job }, 0)[1] == -1
end

---@param dest string
local function forget(dest)
  local master = masters[dest]
  if not master then return end
  masters[dest] = nil
  require("core.pane").release(master.name)
  if vim.api.nvim_buf_is_valid(master.bufnr) then pcall(vim.api.nvim_buf_delete, master.bufnr, { force = true }) end
end

---@param dest string
---@param ok boolean
---@param err? string
local function settle(dest, ok, err)
  local master = masters[dest]
  if not master then return end
  local waiting = master.waiting
  master.waiting = {}
  if ok and not master.revealed then
    require("core.pane").release(master.name)
  elseif not ok then
    forget(dest)
  end
  for _, callback in ipairs(waiting) do
    callback(ok, err)
  end
end

---@param dest string
local function poll(dest)
  local elapsed = 0
  local timer = assert(vim.uv.new_timer())
  timer:start(
    CHECK_INTERVAL_MS,
    CHECK_INTERVAL_MS,
    vim.schedule_wrap(function()
      elapsed = elapsed + CHECK_INTERVAL_MS
      local master = masters[dest]
      if not master then
        timer:stop()
        timer:close()
        return
      end
      if M.connected(dest) then
        timer:stop()
        timer:close()
        return settle(dest, true)
      end
      if not alive(master) then
        timer:stop()
        timer:close()
        return settle(dest, false, "the ssh connection closed -- see the pane for what it said")
      end
      if elapsed >= CONNECT_TIMEOUT_MS then
        timer:stop()
        timer:close()
        return settle(dest, false, "timed out connecting to " .. dest)
      end
      -- Key auth lands in well under a second; anything slower is a prompt that
      -- has to be on screen to be answered.
      if elapsed >= REVEAL_AFTER_MS and not master.revealed then
        master.revealed = true
        require("core.pane").focus(master.name, { enter = true, insert = true })
      end
    end)
  )
end

---@param dest string
---@param on_done fun(ok: boolean, err?: string)
function M.connect(dest, on_done)
  if M.connected(dest) then return on_done(true) end

  local master = masters[dest]
  if master then
    if alive(master) then
      master.waiting[#master.waiting + 1] = on_done
      return
    end
    forget(dest)
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  local name = "ssh " .. dest
  vim.api.nvim_buf_set_name(bufnr, "remote://master/" .. dest)
  masters[dest] = { bufnr = bufnr, name = name, revealed = false, waiting = { on_done } }

  local occupant = {
    name = name,
    bufnr = bufnr,
    close = function() M.disconnect(dest) end,
    title = function() return "Connecting to " .. dest end,
  }
  require("core.pane").add(occupant)

  local cmd = M.cmd(dest, nil)
  table.insert(cmd, #cmd, "-N")
  local job
  vim.api.nvim_buf_call(bufnr, function() job = vim.fn.jobstart(cmd, { term = true }) end)
  if job <= 0 then
    forget(dest)
    return on_done(false, "could not start ssh")
  end
  poll(dest)
end

---@param dest string
function M.disconnect(dest)
  vim.system({ "ssh", "-o", "ControlPath=" .. M.control_path(), "-O", "exit", dest }, { text = true }):wait(3000)
  forget(dest)
end

---@return string[]
function M.active() return vim.tbl_keys(masters) end

---@param dest string
---@param spec string the -L forward specification
---@return integer|nil job
function M.tunnel(dest, spec)
  local cmd = M.cmd(dest, nil)
  table.insert(cmd, #cmd, "-N")
  table.insert(cmd, #cmd, "-L")
  table.insert(cmd, #cmd, spec)
  local job = vim.fn.jobstart(cmd, { detach = false })
  return job > 0 and job or nil
end

return M
