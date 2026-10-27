local schema = require "core.project_actions.schema"

local M = {}

local NOT_TRUSTED = {
  unknown = "Not trusted yet: review it with Edit and run :trust",
  changed = "Changed outside this editor since it was trusted: review it with Edit and run :trust",
  denied = "Denied in the trust database: review it with Edit and run :trust",
}

local TEMPLATE = {
  "{",
  '  "actions": [',
  "    {",
  '      "label": "Build the project",',
  '      "category": "Build",',
  '      "description": "",',
  '      "cmd": ["./build.sh"]',
  "    }",
  "  ]",
  "}",
}

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "Project actions" })
end

---@param path string
---@return string?
local function read(path)
  local file = io.open(path, "rb")
  if not file then return nil end
  local text = file:read "*a"
  file:close()
  return text
end

---@param root string
---@return integer code
---@return string stdout
local function git(root, ...)
  local result = vim.system({ "git", "-C", root, ... }, { text = true }):wait(2000)
  return result.code, vim.trim(result.stdout or "")
end

-- vim.secure.read prompts and offers no allow for a file, so the trust
-- database it writes is read here directly, in its own "<sha256> <path>" format.
---@param path string
---@param text? string
---@return "trusted"|"unknown"|"changed"|"denied"
function M.trust_state(path, text)
  text = text or read(path)
  local database = io.open(vim.fs.joinpath(vim.fn.stdpath "state" --[[@as string]], "trust"), "r")
  if not database then return "unknown" end
  local real = vim.fs.normalize(vim.uv.fs_realpath(path) or path)
  local state = "unknown"
  for line in database:lines() do
    local hash, file = line:match "^(%S+) (.+)$"
    if file == real then
      if hash == "!" then
        state = "denied"
      else
        state = (text and hash == vim.fn.sha256(text)) and "trusted" or "changed"
      end
      break
    end
  end
  database:close()
  return state
end

---@param path string
---@return boolean
function M.hidden(path) return git(schema.root(path), "check-ignore", "-q", "--", path) ~= 1 end

---@param root string
---@return boolean ok
---@return string message
function M.hide(root)
  local code, exclude = git(root, "rev-parse", "--path-format=absolute", "--git-path", "info/exclude")
  if code ~= 0 or exclude == "" then return false, "Not in a git repository, so there is nothing to hide it from" end
  local _, prefix = git(root, "rev-parse", "--show-prefix")
  local entry = "/" .. prefix .. ".nvim/"
  local lines = vim.fn.filereadable(exclude) == 1 and vim.fn.readfile(exclude) or {}
  if vim.list_contains(vim.tbl_map(vim.trim, lines), entry) then return true, entry .. " is already hidden from git" end
  lines[#lines + 1] = entry
  vim.fn.mkdir(vim.fs.dirname(exclude), "p")
  if not pcall(vim.fn.writefile, lines, exclude) then return false, "Could not write " .. exclude end
  return true, ("%s hidden from git in %s"):format(entry, vim.fn.fnamemodify(exclude, ":~"))
end

---@param start string a directory
---@return string?
function M.find(start)
  local dir = start
  while true do
    local path = vim.fs.joinpath(dir, schema.FILE)
    if vim.uv.fs_stat(path) then return path end
    local parent = vim.fs.dirname(dir)
    if parent == dir then return nil end
    dir = parent
  end
end

---@param path string
---@return core.project_actions.Config?
---@return string? reason
local function load(path)
  local text = read(path)
  if not text then return nil, "Cannot read " .. vim.fn.fnamemodify(path, ":~") end
  local trust = M.trust_state(path, text)
  if trust ~= "trusted" then return nil, NOT_TRUSTED[trust] end
  local config, problems = schema.check(text, schema.root(path))
  if not config then return nil, ("%s, line %d: %s"):format(schema.FILE, problems[1].line, problems[1].message) end
  return config
end

---@param path string
---@param label string
---@return core.project_actions.Entry?
---@return string? reason
local function lookup(path, label)
  local config, reason = load(path)
  if not config then return nil, reason end
  for _, entry in ipairs(config.actions) do
    if entry.label == label then
      if entry.problem then return nil, entry.problem end
      return entry
    end
  end
  return nil, ("%s no longer has an action labelled %q"):format(schema.FILE, label)
end

---@param entry core.project_actions.Entry
local function run(entry)
  require("core.autosave").flush()
  require("core.task").run {
    name = entry.label,
    cmd = entry.cmd --[[@as string[] ]],
    cwd = entry.cwd,
    env = entry.env,
    errorformat = entry.errorformat,
    queue = entry.queue,
  }
end

---@param root string
function M.create(root)
  local path = vim.fs.joinpath(root, schema.FILE)
  if not vim.uv.fs_stat(path) then
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    vim.fn.writefile(TEMPLATE, path)
    vim.secure.trust { action = "allow", path = path }
  end
  local ok, message = M.hide(root)
  if not ok then notify(message, vim.log.levels.WARN) end
  vim.cmd.edit(vim.fn.fnameescape(path))
end

---@param ctx core.Context
---@return string
local function start_dir(ctx)
  local file = ctx.file
  if file ~= "" and vim.bo[ctx.bufnr].buftype == "" and not file:find("://", 1, true) then
    return vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(file, ":p")))
  end
  return ctx.cwd
end

---@param path string
---@param folder? string the workspace folder's name, for a file outside the current one
---@return core.Action
local function edit_action(path, folder)
  return {
    id = "edit:" .. path,
    label = folder and ("Edit %s's actions"):format(folder) or "Edit this project's actions",
    category = "Maintenance",
    repeatable = false,
    run = function() vim.cmd.edit(vim.fn.fnameescape(path)) end,
  }
end

---@param path string
---@param folder? string
---@return core.Action[]
local function file_actions(path, folder)
  local list = { edit_action(path, folder) }
  local config, reason = load(path)
  if not config then
    list[2] = {
      id = "unavailable:" .. path,
      label = folder and ("Run %s's actions"):format(folder) or "Run this project's actions",
      category = "Run",
      available = reason,
      run = function() end,
    }
    return list
  end
  for _, entry in ipairs(config.actions) do
    local label = entry.label
    local details = {}
    if entry.description and entry.description ~= "" then details[#details + 1] = entry.description end
    if folder then details[#details + 1] = folder end
    list[#list + 1] = {
      id = ("custom:%s:%s"):format(path, label),
      label = label,
      detail = #details > 0 and table.concat(details, " · ") or nil,
      category = entry.category or "Inspect",
      available = function()
        local _, why = lookup(path, label)
        return why or true
      end,
      run = function() run(assert(lookup(path, label))) end,
    }
  end
  return list
end

---@param ctx core.Context
---@return string? current the file for the buffer's own project
---@return string[] others the files of the other workspace folders
local function files(ctx)
  local current = M.find(start_dir(ctx))
  local others = {}
  for _, folder in ipairs(require("core.workspace").dirs() or {}) do
    local path = vim.fs.joinpath(folder, schema.FILE)
    if path ~= current and vim.uv.fs_stat(path) then others[#others + 1] = path end
  end
  return current, others
end

---@type core.ActionProvider
local provider = {
  id = "project",
  name = "Project",
  priority = 100,

  detect = function(ctx)
    local current, others = files(ctx)
    if current or #others > 0 then
      local count = (current and 1 or 0) + #others
      return count == 1 and vim.fn.fnamemodify(current or others[1], ":~") or ("%d actions files"):format(count)
    end
    return vim.fs.root(start_dir(ctx), ".git") ~= nil
  end,

  actions = function(ctx)
    local current, others = files(ctx)
    local list = {}
    if current then
      list = file_actions(current)
    else
      local root = vim.fs.root(start_dir(ctx), ".git")
      if root then
        list[1] = {
          id = "create",
          label = "Create this project's actions file",
          detail = schema.FILE .. ", hidden from git",
          category = "Maintenance",
          repeatable = false,
          run = function() M.create(root) end,
        }
      end
    end
    for _, path in ipairs(others) do
      vim.list_extend(list, file_actions(path, vim.fs.basename(schema.root(path))))
    end
    return list
  end,
}

---@param bufnr integer
function M.attach(bufnr) vim.lsp.start(require("core.project_actions.server").config, { bufnr = bufnr, silent = true }) end

---@param bufnr integer
function M.on_write(bufnr)
  vim.secure.trust { action = "allow", bufnr = bufnr }
  require("core.project_actions.server").refresh(vim.uri_from_bufnr(bufnr))
end

function M.setup() require("core.actions").register(provider) end

return M
