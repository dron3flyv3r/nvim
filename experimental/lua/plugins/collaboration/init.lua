local GROUP = "plugins_collaboration"
local PLUGIN = "teamtype-nvim"

---@type table<integer, string>
local attached = {}
---@type core.Task?
local daemon
local warned = {}

local function notify(message, level) vim.notify(message, level or vim.log.levels.INFO, { title = "Teamtype" }) end

---@param path string
---@return string?
local function shared_root(path)
  local root = vim.fs.root(path, ".teamtype")
  if root and vim.uv.fs_stat(vim.fs.joinpath(root, ".teamtype", "socket")) then return root end
end

local function load() require("lazy").load { plugins = { PLUGIN } } end

---@param bufnr integer
---@param on_dir fun(root: string)
local function root_dir(bufnr, on_dir)
  if attached[bufnr] then return end
  local root = shared_root(vim.api.nvim_buf_get_name(bufnr))
  if not root then return end
  attached[bufnr] = root
  -- teamtype-nvim turns a write into a no-op and leaves the buffer modified, so
  -- quitting would ask to save a file the daemon has already written.
  vim.api.nvim_create_autocmd("BufWritePre", {
    group = GROUP,
    buffer = bufnr,
    callback = function() vim.bo[bufnr].modified = false end,
  })
  on_dir(root)
end

---@param root string
local function release(root)
  for bufnr, at in pairs(attached) do
    if at == root then
      attached[bufnr] = nil
      if vim.api.nvim_buf_is_valid(bufnr) then
        for _, event in ipairs { "BufWriteCmd", "FileWriteCmd", "FileAppendCmd" } do
          vim.api.nvim_clear_autocmds { event = event, buffer = bufnr }
        end
        vim.api.nvim_clear_autocmds { group = GROUP, event = "BufWritePre", buffer = bufnr }
        vim.bo[bufnr].modifiable = true
        vim.api.nvim_buf_call(bufnr, function() vim.cmd "setlocal autoread<" end)
      end
    end
  end
  notify(("%s is no longer shared; its files save normally again"):format(vim.fn.fnamemodify(root, ":~")))
end

-- The plugin's `open` callback disables writing in whichever buffer is current
-- when the daemon answers, so a buffer loaded in the background handed that to
-- an unrelated one.
local function wrap_connection()
  local connection = require "teamtype.connection"
  local connect = connection.connect
  connection.connect = function(cmd, directory, dispatchers)
    local on_exit = dispatchers.on_exit
    dispatchers.on_exit = function(...)
      on_exit(...)
      vim.schedule(function() release(directory) end)
    end
    local conn = connect(cmd, directory, dispatchers)
    if not conn then return conn end
    local send = conn.send_request
    conn.send_request = function(self, method, params, on_result, on_error)
      if method == "open" and on_result then
        local bufnr, inner = vim.uri_to_bufnr(params.uri), on_result
        on_result = function(result) vim.api.nvim_buf_call(bufnr, function() inner(result) end) end
      end
      return send(self, method, params, on_result, on_error)
    end
    return conn
  end
end

-- 0.13 removed this private helper, and without it the plugin applies no
-- teammate's edit and draws no cursor.
local function restore_line_byte()
  local util = vim.lsp.util
  if util._get_line_byte_from_position then return end
  ---@param bufnr integer
  ---@param position lsp.Position
  ---@param encoding "utf-8"|"utf-16"|"utf-32"
  util._get_line_byte_from_position = function(bufnr, position, encoding)
    if position.character == 0 or not vim.api.nvim_buf_is_loaded(bufnr) then return position.character end
    local line = vim.api.nvim_buf_get_lines(bufnr, position.line, position.line + 1, false)[1] or ""
    return vim.str_byteindex(line, encoding, position.character, false)
  end
end

---@param root string
local function attach_loaded(root)
  load()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(bufnr)
    if
      vim.api.nvim_buf_is_loaded(bufnr)
      and vim.bo[bufnr].buftype == ""
      and not attached[bufnr]
      and name ~= ""
      and vim.fs.relpath(root, name)
    then
      vim.api.nvim_buf_call(
        bufnr,
        function() pcall(vim.api.nvim_exec_autocmds, "BufRead", { buffer = bufnr, modeline = false }) end
      )
    end
  end
end

---@param task core.Task
local function when_shared(task)
  local timer = assert(vim.uv.new_timer())
  timer:start(
    250,
    250,
    vim.schedule_wrap(function()
      if timer:is_closing() then return end
      local root = shared_root(task.cwd)
      if task.status ~= "running" or root then
        timer:close()
        if root and task.status == "running" then attach_loaded(root) end
      end
    end)
  )
end

---@param name string
---@param cmd string[]
---@param cwd string
local function start(name, cmd, cwd)
  daemon = require("core.task").run { name = name, cmd = cmd, cwd = cwd, queue = false, focus = true }
  when_shared(daemon)
end

---@param kind string
---@param message string
local function warn_once(kind, message)
  if warned[kind] or not shared_root(vim.fn.getcwd()) then return end
  warned[kind] = true
  notify(message, vim.log.levels.WARN)
end

---@param ctx core.Context
---@return true|string
local function not_shared(ctx)
  local root = shared_root(ctx.cwd)
  return not root or ("Already shared from " .. vim.fn.fnamemodify(root, ":~"))
end

---@type core.ActionProvider
local provider = {
  id = "collaboration",
  name = "Teamtype",
  priority = 10,
  detect = function() return vim.fn.executable "teamtype" == 1 end,
  actions = function(ctx)
    local follow = require "plugins.collaboration.follow"
    local followed = follow.following()
    local here = vim.fn.fnamemodify(ctx.cwd, ":~")
    return {
      {
        id = "share",
        label = "Share this folder with Teamtype",
        detail = here,
        category = "Run",
        repeatable = false,
        available = function() return not_shared(ctx) end,
        run = function() start("teamtype share", { "teamtype", "share" }, ctx.cwd) end,
      },
      {
        id = "join",
        label = "Join a Teamtype session into this folder",
        detail = here,
        category = "Run",
        repeatable = false,
        available = function() return not_shared(ctx) end,
        run = function()
          vim.ui.input({ prompt = "Join code: " }, function(code)
            code = vim.trim(code or "")
            if code ~= "" then start("teamtype join", { "teamtype", "join", code }, ctx.cwd) end
          end)
        end,
      },
      {
        id = "stop",
        label = "Stop sharing",
        category = "Run",
        repeatable = false,
        available = function()
          return (daemon and daemon.status == "running") or "No Teamtype daemon was started from this editor"
        end,
        run = function() require("core.task").stop(daemon) end,
      },
      {
        id = "follow",
        label = followed and ("Stop following " .. followed) or "Follow a teammate",
        category = "Inspect",
        available = function() return followed ~= nil or shared_root(ctx.cwd) ~= nil or "This folder is not shared" end,
        run = follow.toggle,
      },
    }
  end,
}

require("core.actions").register(provider)

---@type LazySpec
return {
  "teamtype/teamtype-nvim",
  lazy = true,
  init = function()
    local group = vim.api.nvim_create_augroup(GROUP, { clear = true })
    vim.api.nvim_create_autocmd({ "BufReadPre", "BufNewFile" }, {
      group = group,
      callback = function(args)
        if shared_root(args.match) then load() end
      end,
    })
    vim.api.nvim_create_autocmd("BufUnload", {
      group = group,
      callback = function(args) attached[args.buf] = nil end,
    })
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "DiffviewViewOpened",
      callback = function()
        warn_once(
          "review",
          "This folder is shared. A review holds files in memory until q while teammates' edits keep landing in them and on disk, so Save may refuse."
        )
      end,
    })
    vim.api.nvim_create_autocmd("BufEnter", {
      group = group,
      pattern = "agent://*",
      callback = function()
        warn_once("agent", "This folder is shared. An agent writes to disk, and its edits reach every teammate as it makes them.")
      end,
    })
    vim.api.nvim_create_autocmd("VimLeavePre", {
      group = group,
      callback = function()
        local follow = package.loaded["plugins.collaboration.follow"]
        if follow then follow.stop() end
      end,
    })
  end,
  config = function()
    restore_line_byte()
    wrap_connection()
    local teamtype = require "teamtype"
    teamtype.config("teamtype", { cmd = { "teamtype", "client" }, root_dir = root_dir })
    teamtype.enable "teamtype"
    require("plugins.collaboration.follow").track()
  end,
}
