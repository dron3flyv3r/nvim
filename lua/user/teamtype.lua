local M = {}

local process
local stopping = false
local join_code
local logs = {}
local pending = { stdout = "", stderr = "" }
local project_root
local buffers_attached = false

local function notify(message, level) vim.notify(message, level or vim.log.levels.INFO, { title = "Teamtype" }) end

local function copy(text)
  vim.fn.setreg('"', text)
  local system_clipboard = pcall(vim.fn.setreg, "+", text)
  return system_clipboard
end

local function attach_loaded_buffers()
  if buffers_attached then return end
  buffers_attached = true

  vim.schedule(function()
    local root = vim.fs.normalize(project_root or vim.fn.getcwd())
    local prefix = root:sub(-1) == "/" and root or (root .. "/")
    local attached = 0

    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      local name = vim.api.nvim_buf_get_name(buf)
      local normalized = name ~= "" and vim.fs.normalize(name) or ""
      local in_project = normalized == root or normalized:sub(1, #prefix) == prefix
      if vim.api.nvim_buf_is_loaded(buf) and in_project and vim.bo[buf].buftype == "" then
        -- teamtype-nvim normally discovers files during BufRead. The daemon is
        -- started after startup here, so replay that event without reloading
        -- the buffer (and therefore without losing unsaved edits).
        if pcall(vim.api.nvim_exec_autocmds, "BufRead", { buffer = buf, modeline = false }) then
          attached = attached + 1
        end
      end
    end

    notify(attached > 0 and ("Collaboration ready; attached %d open file(s)"):format(attached) or "Collaboration ready")
  end)
end

local function remember(line, stream)
  line = line:gsub("\27%[[%d;]*m", "")
  if line == "" then return end
  logs[#logs + 1] = (stream == "stderr" and "! " or "  ") .. line
  if #logs > 500 then table.remove(logs, 1) end

  local code = line:match "teamtype join%s+([%w-]+)"
  if code and code ~= join_code then
    join_code = code
    vim.schedule(function()
      local system_clipboard = copy(code)
      notify(
        system_clipboard and ("Join code copied: " .. code) or ("Join code ready: " .. code .. " (unnamed register)"),
        vim.log.levels.INFO
      )
    end)
  end

  if code or line:match "^Connected to peer:" then attach_loaded_buffers() end
end

local function consume(data, stream)
  if not data or data == "" then return end
  local text = pending[stream] .. data
  local start = 1
  while true do
    local finish = text:find("\n", start, true)
    if not finish then break end
    remember(text:sub(start, finish - 1), stream)
    start = finish + 1
  end
  pending[stream] = text:sub(start)
end

local function flush_pending()
  for _, stream in ipairs { "stdout", "stderr" } do
    if pending[stream] ~= "" then remember(pending[stream], stream) end
    pending[stream] = ""
  end
end

local function start(args, label)
  if vim.fn.executable "teamtype" ~= 1 then
    notify("`teamtype` is not installed or is not in PATH", vim.log.levels.ERROR)
    return
  end
  if process then
    notify("A Teamtype daemon started by this Neovim is already running", vim.log.levels.WARN)
    return
  end

  join_code = nil
  logs = { ("$ %s"):format(table.concat(args, " ")) }
  pending = { stdout = "", stderr = "" }
  stopping = false
  project_root = vim.fn.getcwd()
  buffers_attached = false

  local current
  current = vim.system(args, {
    cwd = project_root,
    -- Both share and join ask before initializing a directory. Starting either
    -- command is the user's explicit confirmation, and a background process
    -- cannot display an interactive terminal prompt.
    stdin = "y\n",
    text = true,
    stdout = function(_, data) consume(data, "stdout") end,
    stderr = function(_, data) consume(data, "stderr") end,
  }, function(result)
    vim.schedule(function()
      flush_pending()
      if process == current then process = nil end
      local was_stopping = stopping
      stopping = false
      if was_stopping then
        notify "Collaboration stopped; restart Neovim before continuing to edit shared buffers"
      elseif result.code ~= 0 then
        notify(
          ("%s exited with code %d; use :TeamtypeLog for details"):format(label, result.code),
          vim.log.levels.ERROR
        )
      else
        notify(label .. " stopped")
      end
    end)
  end)
  process = current
end

function M.host() start({ "teamtype", "share", "--username", vim.env.USER or "friend" }, "Host daemon") end

function M.join()
  vim.ui.input({ prompt = "Teamtype join code: " }, function(code)
    code = vim.trim(code or "")
    if code == "" then return end
    start({ "teamtype", "join", "--username", vim.env.USER or "friend", code }, "Guest daemon")
  end)
end

function M.copy_code()
  if not join_code then
    notify("No join code yet -- host a session and wait for Teamtype to publish it", vim.log.levels.WARN)
    return
  end
  local system_clipboard = copy(join_code)
  notify(system_clipboard and "Join code copied to the system clipboard" or "Join code copied to the unnamed register")
end

function M.stop()
  if not process then
    notify("No Teamtype daemon started by this Neovim is running", vim.log.levels.WARN)
    return
  end
  stopping = true
  process:kill(15)
end

function M.open_log()
  local buf = vim.api.nvim_create_buf(false, true)
  local content = #logs > 0 and logs or { "No Teamtype daemon output yet." }
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "log"
  vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = math.min(100, vim.o.columns - 8),
    height = math.min(math.max(#content, 4), vim.o.lines - 8),
    row = 2,
    col = 4,
    style = "minimal",
    border = "rounded",
    title = " Teamtype log ",
    title_pos = "center",
  })
  vim.keymap.set("n", "q", "<Cmd>close<CR>", { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Esc>", "<Cmd>close<CR>", { buffer = buf, nowait = true })
end

function M.setup()
  local group = vim.api.nvim_create_augroup("user_teamtype", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      if process then process:kill(15) end
    end,
  })
end

return M
