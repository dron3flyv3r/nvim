local M = {}

local api = vim.api

local MAX_BYTES = 32 * 1024 * 1024

---@type table<table, integer[]>
local buffers = {}

---@param message string
local function say(message) vim.notify(message, vim.log.levels.WARN, { title = "Git" }) end

---@return table?
local function snacks_image()
  local ok, module = pcall(function() return Snacks.image end)
  return ok and module or nil
end

---@return string
local function cache_dir()
  local dir = vim.fs.joinpath(vim.fn.stdpath "cache", "diffview-images")
  vim.fs.mkdir(dir, { parents = true })
  return dir
end

---@param file table
---@return string?
local function object_of(file)
  local rev = file.rev
  if not rev then return nil end
  if rev.commit then return ("%s:%s"):format(rev.commit, file.path) end
  if rev.stage then return (":%d:%s"):format(rev.stage, file.path) end
  return nil
end

---@param toplevel string
---@param object string
---@return string? sha, integer? size, string? err
local function blob_info(toplevel, object)
  local res = vim.system({ "git", "-C", toplevel, "cat-file", "--batch-check" }, {
    stdin = object .. "\n",
    text = true,
  }):wait()
  if res.code ~= 0 then return nil, nil, vim.trim(res.stderr or "git cat-file failed") end

  local sha, size = vim.trim(res.stdout or ""):match "^(%x+) blob (%d+)$"
  if not sha then return nil, nil, "no such blob in this revision" end
  return sha, tonumber(size)
end

---@param file table
---@param object string
---@return string? path, string? err
local function extract(file, object)
  local toplevel = file.adapter and file.adapter.ctx and file.adapter.ctx.toplevel
  if not toplevel then return nil, "no repository for this revision" end

  local sha, size, err = blob_info(toplevel, object)
  if not sha then return nil, err end
  if size and size > MAX_BYTES then return nil, ("%.1f MB is too large to render"):format(size / 1024 / 1024) end

  local dst = vim.fs.joinpath(cache_dir(), ("%s.%s"):format(sha, vim.fn.fnamemodify(file.path, ":e")))
  if vim.uv.fs_stat(dst) then return dst end

  -- Not `adapter:show`, which returns lines: a blob has to stay bytes.
  local blob = vim.system({ "git", "-C", toplevel, "cat-file", "blob", sha }):wait()
  if blob.code ~= 0 then return nil, vim.trim(blob.stderr or "git cat-file failed") end

  local out = io.open(dst, "wb")
  if not out then return nil, ("could not write %s"):format(dst) end
  out:write(blob.stdout or "")
  out:close()
  return dst
end

---@param file table
---@return string? src, string? err
local function source(file)
  local object = object_of(file)
  if object then return extract(file, object) end

  local path = file.absolute_path
  if path and vim.uv.fs_stat(path) then return path end
  return nil, "not on disk"
end

---@param view table
---@param file table
local function load(view, file)
  local module = snacks_image()
  if not module or file.nulled or file:is_valid() then return end
  if not module.supports_file(file.path) then return end

  local src, err = source(file)
  if not src then return say(("%s: %s"):format(file.path, err or "could not be read")) end

  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "hide"

  -- Diffview sends every binary file to one shared null buffer, and that check
  -- runs ahead of the working-tree branch, which is why both panes of an image
  -- are blank. A buffer that is already valid short-circuits the whole path.
  file.bufnr = buf
  file.binary = false

  buffers[view] = buffers[view] or {}
  table.insert(buffers[view], buf)
  module.buf.attach(buf, { src = src })
end

---@param view table
---@param entry table
local function prepare(view, entry)
  local layout = entry and entry.layout
  if not layout then return end
  for _, win in ipairs(layout.windows or {}) do
    if win.file then load(view, win.file) end
  end
end

-- `file_open_pre` is the last point before the layout claims its buffers, and it
-- reaches the view's own emitter rather than the `hooks` table.
---@param view table
function M.watch(view)
  if not (view and view.emitter) then return end
  view.emitter:on("file_open_pre", function(_, entry) prepare(view, entry) end)
end

---@param view table
function M.closed(view)
  for _, buf in ipairs(buffers[view] or {}) do
    if api.nvim_buf_is_valid(buf) then pcall(api.nvim_buf_delete, buf, { force = true }) end
  end
  buffers[view] = nil
end

return M
