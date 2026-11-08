local M = {}

local ssh = require "core.remote.ssh"

local MAX_DEPTH = 6
local MAX_RESULTS = 5000

---@class core.remote.BrowseOpts
---@field host core.remote.Host
---@field kind "file"|"dir"
---@field start? string
---@field on_choice fun(path: string)

---@param message string
---@param level? integer
local function notify(message, level) vim.notify(message, level or vim.log.levels.INFO, { title = "Remote" }) end

---@param here string
---@param name string
---@return string
local function join(here, name) return (here == "/" and "" or here) .. "/" .. name end

---@param dir string
---@return string
local function listing_script(dir)
  return ([[
cd %s 2>/dev/null || { echo "ERR not a directory"; exit 0; }
pwd
ls -1Ap 2>/dev/null
]]):format(ssh.quote(dir))
end

---@param dir string
---@param kind "file"|"dir"
---@return string
local function search_script(dir, kind)
  local flag = kind == "dir" and "d" or "f"
  return ([[
cd %s 2>/dev/null || exit 1
if command -v fd >/dev/null 2>&1; then
  fd --hidden --no-ignore --type %s --max-depth %d --exclude .git --exclude node_modules --exclude .cache . 2>/dev/null
else
  find . -maxdepth %d \( -name .git -o -name node_modules -o -name .cache \) -prune -o -type %s -print 2>/dev/null \
    | sed 's#^\./##'
fi
]]):format(ssh.quote(dir), flag, MAX_DEPTH, MAX_DEPTH, flag)
end

local HERE, UP, SEARCH, TYPE = {}, {}, {}, {}

---@param opts core.remote.BrowseOpts
---@param here string
local function search(opts, here)
  notify(("Searching %s on %s…"):format(here, opts.host.name))
  ssh.script(opts.host.dest, search_script(here, opts.kind), function(lines, failure)
    if failure then
      return notify(("Could not search %s on %s: %s"):format(here, opts.host.name, failure), vim.log.levels.ERROR)
    end
    local found, truncated = {}, false
    for _, line in ipairs(lines) do
      local relative = vim.trim(line):gsub("^%./", ""):gsub("/$", "")
      if relative ~= "" and relative ~= "." then
        if #found >= MAX_RESULTS then
          truncated = true
          break
        end
        found[#found + 1] = relative
      end
    end
    if #found == 0 then return notify(("Nothing found under %s on %s"):format(here, opts.host.name)) end
    table.sort(found)
    local label = ("%s under %s%s"):format(
      opts.kind == "dir" and "Folders" or "Files",
      here,
      truncated and " (first " .. MAX_RESULTS .. ")" or ""
    )
    vim.ui.select(found, { prompt = label }, function(choice)
      if choice then opts.on_choice(join(here, choice)) end
    end)
  end)
end

---@param opts core.remote.BrowseOpts
---@param dir string
function M.browse(opts, dir)
  ssh.script(opts.host.dest, listing_script(dir), function(lines, failure)
    if failure then
      return notify(("Could not list %s on %s: %s"):format(dir, opts.host.name, failure), vim.log.levels.ERROR)
    end
    if lines[1] == "ERR not a directory" then
      return notify(dir .. " is not a directory on " .. opts.host.name, vim.log.levels.WARN)
    end

    local here = table.remove(lines, 1)
    if not here then
      return notify(("%s listed %s as nothing at all"):format(opts.host.name, dir), vim.log.levels.ERROR)
    end
    local items = {}
    if opts.kind == "dir" then items[#items + 1] = HERE end
    if here ~= "/" then items[#items + 1] = UP end
    local dirs, files = {}, {}
    for _, entry in ipairs(lines) do
      -- ls -F marks sockets, fifos and executables too; only a directory is one to enter.
      if entry:sub(-1) == "/" then
        dirs[#dirs + 1] = entry
      elseif opts.kind == "file" and not entry:find "[*=>|]$" then
        files[#files + 1] = entry
      end
    end
    vim.list_extend(items, dirs)
    vim.list_extend(items, files)
    items[#items + 1] = SEARCH
    items[#items + 1] = TYPE

    vim.ui.select(items, {
      prompt = ("%s:%s"):format(opts.host.name, here),
      format_item = function(item)
        if item == HERE then return "Use this folder  (" .. here .. ")" end
        if item == UP then return "../" end
        if item == SEARCH then
          return ("Search for a %s below here…"):format(opts.kind == "dir" and "folder" or "file")
        end
        if item == TYPE then return "Type a path…" end
        return item
      end,
    }, function(choice)
      if not choice then return end
      if choice == HERE then return opts.on_choice(here) end
      if choice == UP then return M.browse(opts, vim.fs.dirname(here)) end
      if choice == SEARCH then return search(opts, here) end
      if choice == TYPE then
        return vim.ui.input({ prompt = "Path on " .. opts.host.name .. ": ", default = here }, function(input)
          if input and vim.trim(input) ~= "" then M.enter(opts, vim.trim(input)) end
        end)
      end
      local path = join(here, choice)
      if choice:sub(-1) == "/" then return M.browse(opts, path:sub(1, -2)) end
      opts.on_choice(path)
    end)
  end)
end

-- A typed path may be either, and asking the server is cheaper than a wrong guess.
---@param opts core.remote.BrowseOpts
---@param path string
function M.enter(opts, path)
  local probe = ("[ -d %s ] && echo DIR || echo FILE"):format(ssh.quote(path))
  ssh.script(opts.host.dest, probe, function(lines, failure)
    if failure then
      return notify(("Could not reach %s on %s: %s"):format(path, opts.host.name, failure), vim.log.levels.ERROR)
    end
    local directory = vim.trim(lines[1] or "") == "DIR"
    if opts.kind == "dir" then
      if directory then return opts.on_choice(path) end
      return notify(path .. " is not a directory on " .. opts.host.name, vim.log.levels.WARN)
    end
    if directory then return M.browse(opts, path) end
    opts.on_choice(path)
  end)
end

---@param opts core.remote.BrowseOpts
function M.start(opts)
  ssh.connect(opts.host.dest, function(ok, err)
    if not ok then return notify(err or "could not connect to " .. opts.host.name, vim.log.levels.ERROR) end
    M.browse(opts, opts.start or opts.host.last or ".")
  end)
end

return M
