local M = {}

local FileChangeType = vim.lsp.protocol.FileChangeType

--- Is `path` inside `dir`?
---@param dir string
---@param path string
---@return boolean
local function contains(dir, path)
  local rel = vim.fs.relpath(dir, path)
  return rel ~= nil and rel:sub(1, 2) ~= ".."
end

---@param path string
---@return vim.lsp.Client[]
local function clients_owning(path)
  return vim.tbl_filter(function(client)
    local folders = client.workspace_folders
    if not folders or #folders == 0 then return true end
    for _, folder in ipairs(folders) do
      if contains(vim.uri_to_fname(folder.uri), path) then return true end
    end
    return false
  end, vim.lsp.get_clients())
end

--- Send `workspace/didChangeWatchedFiles` for one path.
---@param path string absolute path
---@param change_type integer one of `vim.lsp.protocol.FileChangeType`
---@param clients vim.lsp.Client[]? override for paths that live outside any
---  workspace, where `clients_owning` would correctly find nobody -- see
---  `python_env.lua`, which watches a virtualenv that may sit anywhere
local function notify(path, change_type, clients)
  if path == "" then return end
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  local params = { changes = { { uri = vim.uri_from_fname(path), type = change_type } } }
  for _, client in ipairs(clients or clients_owning(path)) do
    client:notify("workspace/didChangeWatchedFiles", params)
  end
end

---@param path string
---@param clients vim.lsp.Client[]?
function M.created(path, clients) notify(path, FileChangeType.Created, clients) end

---@param path string
---@param clients vim.lsp.Client[]?
function M.deleted(path, clients) notify(path, FileChangeType.Deleted, clients) end

---@param from string
---@param to string
function M.moved(from, to)
  notify(from, FileChangeType.Deleted)
  notify(to, FileChangeType.Created)
end

-- Paths that a `*WritePre` saw were not on disk yet, waiting for the matching
-- `*WritePost`. Marking has to happen before the write, because afterwards the
-- file exists either way and there is nothing left to tell apart.
---@type table<string, true>
local pending = {}

--- Remember `path` if the write about to happen will create it.
---@param path string
function M.mark_if_new(path)
  -- Anything with a `://` prefix -- fugitive, a remote path -- has no file
  -- behind it to stat.
  if path == "" or path:match "^%w+://" then return end
  if not vim.uv.fs_stat(path) then pending[path] = true end
end

--- Announce `path` if the write that just happened created it.
---@param path string
function M.flush_if_new(path)
  if not pending[path] then return end
  pending[path] = nil
  M.created(path)
end

return M
