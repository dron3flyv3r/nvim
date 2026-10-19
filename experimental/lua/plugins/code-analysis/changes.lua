local control = require "plugins.code-analysis.control"

local M = {}

local UPSTREAM = "origin/HEAD"

local function notify(message, level) vim.notify(message, level or vim.log.levels.INFO, { title = "Sonar" }) end

---@param root string
---@param args string[]
---@return string?
local function git(root, args)
  local result = vim.system(vim.list_extend({ "git", "-C", root }, args), { text = true }):wait(5000)
  if result.code == 0 then return result.stdout end
end

---@param root string
---@param args string[]
---@return string[]
local function git_paths(root, args) return vim.split(git(root, args) or "", "\0", { trimempty = true }) end

---@param root string
---@param base string
---@return string[]
local function changed_paths(root, base)
  local seen, paths = {}, {}
  local function add(path)
    if seen[path] or not vim.uv.fs_stat(path) or not control.handles_path(path) then return end
    seen[path] = true
    paths[#paths + 1] = path
  end
  for _, name in ipairs(git_paths(root, { "diff", "-z", "--name-only", "--relative", base })) do
    add(vim.fs.joinpath(root, name))
  end
  for _, name in ipairs(git_paths(root, { "ls-files", "-z", "--others", "--exclude-standard" })) do
    add(vim.fs.joinpath(root, name))
  end
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(bufnr)
    if vim.bo[bufnr].modified and vim.fs.relpath(root, name) then add(name) end
  end
  return paths
end

-- Diagnostics are on the buffer's lines, unsaved edits included, so the buffer
-- is what is diffed against the base rather than the file on disk.
---@param root string
---@param base string
---@param bufnr integer
---@return table<integer, true>
local function changed_lines(root, base, bufnr)
  local lines = {}
  local path = vim.fs.relpath(root, vim.api.nvim_buf_get_name(bufnr))
  local before = path and git(root, { "show", ("%s:./%s"):format(base, path) })
  local after = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if not before then
    for lnum = 1, #after do
      lines[lnum] = true
    end
    return lines
  end
  ---@type integer[][]
  local hunks = vim.diff((before:gsub("\r\n", "\n")), table.concat(after, "\n") .. "\n", { result_type = "indices" })
  for _, hunk in ipairs(hunks) do
    for lnum = hunk[3], hunk[3] + hunk[4] - 1 do
      lines[lnum] = true
    end
  end
  return lines
end

---@param root string
---@param base string
---@param buffers integer[]
---@return table[]
local function picker_items(root, base, buffers)
  local items = {}
  for _, bufnr in ipairs(buffers) do
    local diagnostics = control.diagnostics(bufnr)
    local lines = #diagnostics > 0 and changed_lines(root, base, bufnr) or {}
    local file = vim.api.nvim_buf_get_name(bufnr)
    for _, diagnostic in ipairs(diagnostics) do
      if lines[diagnostic.lnum + 1] then
        items[#items + 1] = {
          text = table.concat({ tostring(diagnostic.code or ""), file, diagnostic.message }, " "),
          file = file,
          buf = bufnr,
          severity = diagnostic.severity,
          pos = { diagnostic.lnum + 1, diagnostic.col },
          end_pos = diagnostic.end_lnum and { diagnostic.end_lnum + 1, diagnostic.end_col } or nil,
          item = diagnostic,
        }
      end
    end
  end
  table.sort(items, function(a, b)
    if a.severity ~= b.severity then return a.severity < b.severity end
    if a.file ~= b.file then return a.file < b.file end
    return a.pos[1] < b.pos[1]
  end)
  return items
end

---@param paths string[]
---@return integer[] buffers, integer[] waiting
local function load(paths)
  local buffers, waiting = {}, {}
  for _, path in ipairs(paths) do
    local bufnr = vim.fn.bufadd(path)
    if not vim.api.nvim_buf_is_loaded(bufnr) then vim.fn.bufload(bufnr) end
    buffers[#buffers + 1] = bufnr
    if not control.analysed(bufnr) then waiting[#waiting + 1] = bufnr end
  end
  return buffers, waiting
end

---@param root string
local function run(root)
  local base = vim.trim(git(root, { "merge-base", "HEAD", UPSTREAM }) or "")
  if base == "" then
    return notify(
      ("Cannot find where this branch left %s; try git remote set-head origin --auto"):format(UPSTREAM),
      vim.log.levels.WARN
    )
  end
  local upstream = vim.trim(git(root, { "rev-parse", "--abbrev-ref", UPSTREAM }) or UPSTREAM)
  local paths = changed_paths(root, base)
  if #paths == 0 then return notify(("Nothing Sonar analyses has changed since %s"):format(upstream)) end

  local buffers, waiting = load(paths)
  if #waiting > 0 then notify(("Analysing %d changed file%s..."):format(#waiting, #waiting == 1 and "" or "s")) end
  local pending = control.await_analysis(waiting)

  local title = ("Sonar · my changes since %s"):format(upstream)
  if #pending > 0 then title = title .. (" · %d not analysed"):format(#pending) end
  local items = picker_items(root, base, buffers)
  if #items == 0 then return notify(title .. " · no issues") end
  require("snacks").picker {
    title = title,
    items = items,
    format = "diagnostic",
    focus = "list",
    sort = { fields = { "score:desc", "idx" } },
    matcher = { sort_empty = true },
  }
end

-- Changed files that are not open are loaded as hidden buffers and stay loaded:
-- Sonar analyses open buffers only, and unloading one discards its analysis.
---@param root string
function M.show(root)
  coroutine.wrap(function()
    local ok, err = xpcall(run, debug.traceback, root)
    if not ok then notify(err, vim.log.levels.ERROR) end
  end)()
end

return M
