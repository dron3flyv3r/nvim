-- The device's log, in a buffer that outlives the debugger.
--
-- Deliberately not tied to a session: most of what a tablet has to say it says
-- while running, and the moment you most want the log is the one where attaching
-- failed, or where the thing you are chasing killed the app. So it starts and
-- stops on its own; the debugger merely turns it on when it attaches.
local M = {}

--- Logcat on a busy frame loop will fill anything, and a buffer that grows
--- without limit takes the session with it.
local SCROLLBACK = 5000

--- Batched: appending per line redraws faster than a chatty app can be read.
local FLUSH_MS = 120

local SEVERITY = {
  V = { label = "V", hl = "Comment" },
  D = { label = "D", hl = "Comment" },
  I = { label = "I", hl = "DiagnosticInfo" },
  W = { label = "W", hl = "DiagnosticWarn" },
  E = { label = "E", hl = "DiagnosticError" },
  F = { label = "F", hl = "DiagnosticError" },
}

local state = {
  buf = nil, ---@type integer|nil
  process = nil, ---@type vim.SystemObj|nil
  serial = nil, ---@type string|nil
  root = nil, ---@type string|nil
  pid = nil, ---@type integer|nil
  -- Bumped on every start and stop. A killed process reports its exit after the
  -- next one has already been spawned, and without this the stale callback
  -- tears down its successor -- which is exactly what a reconnect does.
  generation = 0,
  pending = {},
  timer = nil, ---@type uv.uv_timer_t|nil
  follow = true,
}

local namespace = vim.api.nvim_create_namespace "unity_android_logcat"

--- An event keeps the knowledge here and the layout decision in the dock, the
--- way the editor state and the statusline are already split.
local function announce() pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "UnityLogcat" }) end

--- `-v time` prefixes date, severity, tag and pid. The date is today's and the
--- pid does not change, so neither earns any width; the clock does.
---@param line string
---@return string text, string|nil severity
function M.parse_line(line)
  local time, severity, tag, message =
    line:match "^%d%d%-%d%d (%d%d:%d%d:%d%d)%.%d+ ([VDIWEF])/(.-)%s*%(%s*%d+%):%s?(.*)$"
  if not time then return line, nil end
  return ("%s %s %-10s %s"):format(time, severity, tag, message), severity
end

--- A file and a line out of a stack frame, in either of the two shapes Unity
--- produces: its own `(at Assets/Foo.cs:42)`, and Mono's `in /path/Foo.cs:42`.
---@param line string
---@return string|nil file, integer|nil lnum
function M.parse_frame(line)
  local file, lnum = line:match "%(at%s+([^():]+%.cs):(%d+)%)"
  if not file then
    file, lnum = line:match "%sin%s+([^\n:]-%.cs):(%d+)"
  end
  if not file or not lnum then return nil, nil end
  -- IL2CPP writes this in place of a path when the build carries no line table.
  if file:find "<" then return nil, nil end
  return file, tonumber(lnum)
end

---@return integer
function M.buffer()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then return state.buf end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "unitylogcat"
  vim.bo[buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, buf, "unity://logcat")

  vim.keymap.set("n", "<CR>", M.goto_frame, { buffer = buf, desc = "Jump to the frame under the cursor" })
  vim.keymap.set("n", "gf", M.goto_frame, { buffer = buf, desc = "Jump to the frame under the cursor" })
  vim.keymap.set("n", "F", M.toggle_follow, { buffer = buf, desc = "Follow the tail" })
  vim.keymap.set("n", "C", M.clear, { buffer = buf, desc = "Clear the log" })
  -- Not `M.stop`: the timer alongside this is what would otherwise be left
  -- polling a tablet nobody is watching any more.
  vim.keymap.set(
    "n",
    "q",
    function() require("user.integrations.unity.android").unwatch() end,
    { buffer = buf, desc = "Stop watching the device" }
  )

  state.buf = buf
  return buf
end

--- Only windows whose cursor is already at the bottom: scrolling out from under
--- someone who paged up to read something is how a log window becomes useless.
local function follow_tail(buf, previous_last)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      local row = vim.api.nvim_win_get_cursor(win)[1]
      if state.follow and row >= previous_last then
        local last = vim.api.nvim_buf_line_count(buf)
        pcall(vim.api.nvim_win_set_cursor, win, { last, 0 })
      end
    end
  end
end

local function flush()
  local lines = state.pending
  if #lines == 0 then return end
  state.pending = {}

  local buf = M.buffer()
  if not vim.api.nvim_buf_is_valid(buf) then return end

  local previous_last = vim.api.nvim_buf_line_count(buf)
  local empty = previous_last == 1 and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""

  local text, severities = {}, {}
  for _, line in ipairs(lines) do
    local formatted, severity = M.parse_line(line)
    table.insert(text, formatted)
    table.insert(severities, severity)
  end

  vim.bo[buf].modifiable = true
  local start = empty and 0 or previous_last
  vim.api.nvim_buf_set_lines(buf, start, -1, false, text)

  for index, severity in ipairs(severities) do
    local look = severity and SEVERITY[severity]
    if look and look.hl ~= "Comment" then
      pcall(vim.api.nvim_buf_set_extmark, buf, namespace, start + index - 1, 0, {
        end_row = start + index,
        hl_group = look.hl,
        hl_eol = false,
      })
    end
  end

  local total = vim.api.nvim_buf_line_count(buf)
  if total > SCROLLBACK then vim.api.nvim_buf_set_lines(buf, 0, total - SCROLLBACK, false, {}) end
  vim.bo[buf].modifiable = false

  follow_tail(buf, previous_last)
end

local function ensure_timer()
  if state.timer then return end
  state.timer = assert(vim.uv.new_timer())
  state.timer:start(FLUSH_MS, FLUSH_MS, vim.schedule_wrap(flush))
end

local function stop_timer()
  if not state.timer then return end
  state.timer:stop()
  if not state.timer:is_closing() then state.timer:close() end
  state.timer = nil
end

---@return boolean
function M.running() return state.process ~= nil end

--- What the monitor compares against, so a log on a stale pid repairs itself.
---@return integer|nil
function M.pid() return state.process and state.pid or nil end

--- `pid` narrows it to the player: the device's log is every app at once, and
--- the rest is noise you cannot read past.
---@param serial string
---@param pid integer
---@param root string|nil Unity project root, for resolving `Assets/...` frames.
---@return boolean ok, string|nil err
function M.start(serial, pid, root)
  M.stop()

  local device = require "user.integrations.unity.android.device"
  local adb = device.adb()
  if not adb then return false, "adb is not installed" end

  state.serial, state.root, state.pid, state.follow = serial, root, pid, true
  state.generation = state.generation + 1
  local generation = state.generation

  local partial = ""
  local function on_output(_, data)
    if not data then return end
    -- A chunk boundary lands wherever the pipe filled up, which is usually
    -- mid-line.
    local chunk = partial .. data
    local last_break = chunk:find "\n[^\n]*$"
    if not last_break then
      partial = chunk
      return
    end
    partial = chunk:sub(last_break + 1)
    for line in chunk:sub(1, last_break):gmatch "[^\r\n]+" do
      table.insert(state.pending, line)
    end
  end

  local ok, process = pcall(
    vim.system,
    { adb, "-s", serial, "logcat", "--pid=" .. pid, "-v", "time" },
    { text = true, stdout = on_output, stderr = on_output },
    vim.schedule_wrap(function()
      if state.generation ~= generation then return end
      state.process = nil
      stop_timer()
      flush()
      announce()
    end)
  )
  if not ok then return false, tostring(process) end

  state.process = process
  ensure_timer()
  announce()
  return true, nil
end

function M.stop()
  local was_running = state.process ~= nil
  state.generation = state.generation + 1
  if state.process then
    pcall(function() state.process:kill "sigterm" end)
    state.process = nil
  end
  stop_timer()
  flush()
  if was_running then announce() end
end

function M.toggle_follow()
  state.follow = not state.follow
  vim.notify(state.follow and "Following the tail" or "Tail paused", vim.log.levels.INFO, { title = "Logcat" })
end

function M.clear()
  local buf = M.buffer()
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
  vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
  vim.bo[buf].modifiable = false
end

---@param line string
---@return string|nil path, integer|nil lnum
function M.resolve(line)
  local file, lnum = M.parse_frame(line)
  if not file then return nil, nil end
  if vim.startswith(file, "/") then return file, lnum end
  local root = state.root
  return root and (root .. "/" .. file) or file, lnum
end

--- Jump to the source behind the stack frame under the cursor.
function M.goto_frame()
  local line = vim.api.nvim_get_current_line()
  local path, lnum = M.resolve(line)
  if not path then return vim.notify("No stack frame on this line", vim.log.levels.INFO, { title = "Logcat" }) end
  if vim.fn.filereadable(path) ~= 1 then
    return vim.notify(("%s is not in this project"):format(path), vim.log.levels.WARN, { title = "Logcat" })
  end

  -- Out of the dock and into a real window: the log pane is too short to read
  -- code in, and replacing it would lose the log.
  local target = nil
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].buftype == "" then
      target = win
      break
    end
  end
  if target then vim.api.nvim_set_current_win(target) end
  vim.cmd.edit(vim.fn.fnameescape(path))
  pcall(vim.api.nvim_win_set_cursor, 0, { lnum or 1, 0 })
end

function M.frames()
  local buf = M.buffer()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  local items = {}
  for index = #lines, 1, -1 do
    local path, lnum = M.resolve(lines[index])
    if path then
      table.insert(items, {
        text = lines[index],
        file = path,
        pos = { lnum or 1, 0 },
      })
    end
  end

  if #items == 0 then return vim.notify("No stack frames in the log", vim.log.levels.INFO, { title = "Logcat" }) end
  require("snacks").picker { title = "Device stack frames", items = items, format = "file" }
end

return M
