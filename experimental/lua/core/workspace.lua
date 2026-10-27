local M = {}

---@type string[]
local extras = {}
local loaded_for

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "Workspace" })
end

---@param path string
---@return string
local function normalize(path)
  return vim.fs.normalize(vim.fs.abspath(vim.fs.normalize(path, { expand_env = false })), { expand_env = false })
end

---@return string
local function primary() return require("core.session").root() end

---@return string
local function store()
  local directory = vim.fs.joinpath(vim.fn.stdpath "state" --[[@as string]], "workspaces")
  return vim.fs.joinpath(directory, vim.fs.slug(primary()) .. ".json")
end

local function load()
  if loaded_for == primary() then return end
  loaded_for, extras = primary(), {}
  local file = io.open(store(), "r")
  if not file then return end
  local ok, decoded = pcall(vim.json.decode, file:read "*a")
  file:close()
  if ok and type(decoded) == "table" and type(decoded.folders) == "table" then
    for _, folder in ipairs(decoded.folders) do
      if type(folder) == "string" then extras[#extras + 1] = folder end
    end
  end
end

local function save()
  local path = store()
  if #extras == 0 then
    vim.uv.fs_unlink(path)
    return
  end
  vim.fs.mkdir(vim.fs.dirname(path), { parents = true })
  vim.fn.writefile({ vim.json.encode { folders = extras } }, path)
end

---@return string[] folders the project's root first, then every added folder that still exists
function M.folders()
  load()
  local folders = { primary() }
  for _, folder in ipairs(extras) do
    if vim.fn.isdirectory(folder) == 1 then folders[#folders + 1] = folder end
  end
  return folders
end

---@return boolean
function M.active()
  load()
  return #extras > 0
end

---@return string[]? dirs every folder, or nil when the workspace is the project alone
function M.dirs()
  if not M.active() then return nil end
  return M.folders()
end

---@param path string
---@return string?
function M.folder_of(path)
  path = normalize(path)
  local best
  for _, folder in ipairs(M.folders()) do
    if (path == folder or vim.startswith(path, folder .. "/")) and (not best or #folder > #best) then best = folder end
  end
  return best
end

---@param folder string
local function enter(folder)
  local cwd = normalize(vim.fn.getcwd())
  if cwd == folder or vim.startswith(cwd, folder .. "/") then return end
  vim.cmd.cd(vim.fn.fnameescape(folder))
end

---@param bufnr integer
function M.follow(bufnr)
  if vim.bo[bufnr].buftype ~= "" or not M.active() then return end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" or name:find("://", 1, true) then return end
  local folder = M.folder_of(name)
  if folder then enter(folder) end
end

---@param path string
---@return boolean
function M.add(path)
  local folder = normalize(path)
  if vim.fn.isdirectory(folder) ~= 1 then
    notify("Not a directory: " .. vim.fn.fnamemodify(folder, ":~"), vim.log.levels.WARN)
    return false
  end
  folder = vim.fs.root(folder, ".git") or folder
  if vim.list_contains(M.folders(), folder) then
    notify(vim.fn.fnamemodify(folder, ":~") .. " is already in the workspace")
    return false
  end
  extras[#extras + 1] = folder
  save()
  notify(("Added %s (%d folders)"):format(vim.fn.fnamemodify(folder, ":~"), #extras + 1))
  return true
end

---@param path string
---@return boolean
function M.remove(path)
  local folder = normalize(path)
  load()
  for i, extra in ipairs(extras) do
    if extra == folder then
      table.remove(extras, i)
      save()
      if vim.startswith(normalize(vim.fn.getcwd()) .. "/", folder .. "/") then enter(primary()) end
      notify("Removed " .. vim.fn.fnamemodify(folder, ":~"))
      return true
    end
  end
  notify(vim.fn.fnamemodify(folder, ":~") .. " is not an added folder", vim.log.levels.WARN)
  return false
end

---@param callback fun(folders: string[])
local function find_repositories(callback)
  if vim.fn.executable "fd" ~= 1 then return callback {} end
  local home = assert(vim.uv.os_homedir())
  local cmd = { "fd", "--hidden", "--no-ignore", "--type", "d", "--max-depth", "5", "--prune", "^\\.git$", home }
  for _, skip in ipairs { "node_modules", ".cache", ".local", ".cargo", ".npm", "Library" } do
    vim.list_extend(cmd, { "--exclude", skip })
  end
  vim.system(cmd, { text = true }, function(result)
    local folders = {}
    for line in (result.stdout or ""):gmatch "[^\n]+" do
      folders[#folders + 1] = vim.fs.dirname(normalize(line))
    end
    table.sort(folders)
    vim.schedule(function() callback(folders) end)
  end)
end

local TYPE, ADD, REMOVE = {}, {}, {}

function M.pick_add()
  find_repositories(function(repositories)
    local present = M.folders()
    local items = { TYPE }
    for _, folder in ipairs(repositories) do
      if not vim.list_contains(present, folder) then items[#items + 1] = folder end
    end
    vim.ui.select(items, {
      prompt = "Add a folder to the workspace",
      format_item = function(item) return item == TYPE and "Type a path…" or vim.fn.fnamemodify(item, ":~") end,
    }, function(choice)
      if not choice then return end
      if choice ~= TYPE then return M.add(choice) end
      vim.ui.input({ prompt = "Folder: ", completion = "dir", default = "~/" }, function(input)
        if input and input ~= "" then M.add(input) end
      end)
    end)
  end)
end

function M.pick_remove()
  load()
  if #extras == 0 then return notify "No folders have been added to this workspace" end
  vim.ui.select(extras, {
    prompt = "Remove a folder from the workspace",
    format_item = function(folder) return vim.fn.fnamemodify(folder, ":~") end,
  }, function(choice)
    if choice then M.remove(choice) end
  end)
end

function M.pick()
  local items = vim.list_extend(M.folders(), { ADD })
  if M.active() then items[#items + 1] = REMOVE end
  local first = items[1]
  vim.ui.select(items, {
    prompt = "Workspace",
    format_item = function(item)
      if item == ADD then return "Add a folder…" end
      if item == REMOVE then return "Remove a folder…" end
      return vim.fn.fnamemodify(item, ":~") .. (item == first and "  (project)" or "")
    end,
  }, function(choice)
    if choice == ADD then return M.pick_add() end
    if choice == REMOVE then return M.pick_remove() end
    if not choice then return end
    vim.cmd.cd(vim.fn.fnameescape(choice))
    vim.cmd.edit(vim.fn.fnameescape(choice))
  end)
end

---@param ctx core.statusline.Context
---@return string?
local function component(ctx)
  if not M.active() then return nil end
  local folder = M.folder_of(vim.api.nvim_buf_get_name(ctx.bufnr)) or normalize(vim.fn.getcwd())
  return "󰉋 " .. vim.fs.basename(folder)
end

function M.setup()
  require("core.statusline").register("workspace", { side = "left", order = 5, min_width = 60, text = component })
  vim.api.nvim_create_user_command("Workspace", M.pick, { desc = "Jump to, add or remove a workspace folder" })
  vim.api.nvim_create_user_command("WorkspaceAdd", function(args)
    if args.args == "" then return M.pick_add() end
    M.add(args.args)
  end, { nargs = "?", complete = "dir", desc = "Add a folder to the workspace" })
  vim.api.nvim_create_user_command("WorkspaceRemove", function(args)
    if args.args == "" then return M.pick_remove() end
    M.remove(args.args)
  end, {
    nargs = "?",
    complete = function() return vim.tbl_map(function(f) return vim.fn.fnamemodify(f, ":~") end, extras) end,
    desc = "Remove a folder from the workspace",
  })
end

return M
