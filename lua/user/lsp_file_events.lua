-- Telling language servers that a file appeared, disappeared or moved.
--
-- THE PROBLEM: create `utils.py` in a project you already have open, save it,
-- then write `from utils import thing` in another buffer. basedpyright answers
-- `Import "utils" could not be resolved`, `utils.` offers no completions, and
-- it stays that way until you restart Neovim.
--
-- Nothing is wrong with the import. The server simply does not know the file
-- exists. A language server reads the project from disk once and then caches
-- it -- including the *failed* import lookups -- and it finds out about later
-- changes on disk from the client, through the
-- `workspace/didChangeWatchedFiles` notification. Editing a file it already
-- knows about is a different mechanism (`textDocument/didChange`, sent for
-- open buffers), which is why edits show up instantly and new files do not.
--
-- WHY NEOVIM DOES NOT SEND IT ON LINUX: the notification is normally driven by
-- the server registering watch patterns and Neovim watching them. Neovim only
-- advertises that it can do this on macOS and Windows -- on Linux and BSD it
-- reports `didChangeWatchedFiles.dynamicRegistration = false`, so no server
-- ever asks. See `runtime/lua/vim/lsp/protocol.lua`:
--
--     -- TODO(lewis6991): do not advertise didChangeWatchedFiles on Linux
--     -- or BSD since all the current backends are too limited.
--
-- The backends it means are `inotifywait` and a libuv poller, and the reason
-- they are too limited is that they recursively watch everything under the
-- workspace root -- `.venv`, `node_modules`, `build/` and all -- for the whole
-- session. Turning the capability back on is one line, and it is the fix that
-- gets suggested most often, but it buys watching a virtualenv full of
-- thousands of directories to catch the handful of files you create by hand.
--
-- SO: no watchers. The events we care about all pass through Neovim already --
-- you write a new buffer, or you add/delete/rename in neo-tree -- and this
-- module just says so, at the moment it happens, to the servers that own that
-- path. The rest of the tree is not watched, and nothing runs when idle.
--
-- The servers act on it. basedpyright maps the notification onto its internal
-- file watcher and invalidates the cached import resolution; pyrefly and ruff
-- handle it too. Both `type = Created` and `type = Deleted` are enough to make
-- basedpyright re-analyse the open buffers, so the stale error clears on its
-- own without touching the file that has it.
--
-- NOT THE SAME THING AS AstroLSP's `file_operations`, which is already wired up
-- and which fires on exactly the same moments. That sends the *other* family of
-- notifications -- `workspace/didCreateFiles`, `willRenameFiles` and friends --
-- and a server only receives them if it advertises support. basedpyright
-- advertises one member of the family:
--
--     fileOperations = { willRename = { filters = { { pattern = { glob = "**/*" } } } } }
--
-- That is the hook for rewriting `import` statements in other files when you
-- rename one, and it is worth having. But there is no `didCreate` in that list,
-- so the create half of `file_operations` is delivered to nobody, and creating a
-- file stays invisible. Different notification, different capability, hence a
-- second mechanism rather than a change to that one.
--
-- WHAT IS STILL NOT COVERED: files created by something outside Neovim -- a
-- `git checkout` in another terminal, a scaffolding tool, a task run from
-- `<Leader>r`. Those still need `:LspRestart`. Covering them is what the
-- recursive watchers would be for.
--
-- Wired up in `plugins/lsp-file-events.lua`.

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

--- The running servers that could care about `path`.
---
--- A server with no workspace folders is a single-file server and gets told
--- regardless; one with folders is only told about paths inside them, so
--- lua_ls is not woken up by a Python file three projects away.
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

--- A move or a rename: gone from one place, arrived in another.
---
--- Note this is *not* `workspace/willRenameFiles`, which is what makes a server
--- rewrite the imports in other files -- AstroLSP's `file_operations` handles
--- that separately. This is only the bookkeeping half.
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
