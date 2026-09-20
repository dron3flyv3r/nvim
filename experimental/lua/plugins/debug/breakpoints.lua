local M = {}

--- What was turned off, so it can be turned back on. DAP has no notion of a
--- disabled breakpoint -- an adapter only knows the set it was last sent -- so
--- muting is remembering the set, sending an empty one, and restoring later.
local muted = nil

local function say(message, level) vim.notify(message, level or vim.log.levels.INFO, { title = "Debug" }) end

---@return string
local function store_dir() return vim.fs.joinpath(vim.fn.stdpath "data", "dap") end

---@param root string
---@return string
function M.store_path(root) return vim.fs.joinpath(store_dir(), vim.fs.slug(root) .. ".json") end

---@param sessions table<integer, table>
---@param fn fun(session: table)
local function broadcast(sessions, fn)
  for _, session in pairs(sessions) do
    fn(session)
    broadcast(session.children, fn)
  end
end

--- Hand every session the set it should be holding, naming the buffers whose
--- breakpoints are gone so that emptying one is an update rather than a silence.
---
--- `dap.breakpoints.get` drops a buffer from its result the moment the last
--- breakpoint in it is gone, and `Session:set_breakpoints` returns without
--- sending anything when handed a table with no entries at all. Between them,
--- "there are none left anywhere" -- which is what muting and clearing produce --
--- never reaches the adapter: the signs disappear and the program goes on
--- stopping at breakpoints that are no longer on screen.
---@param emptied? table<integer, boolean>
local function sync(emptied)
  local points = require("dap.breakpoints").get()
  for bufnr in pairs(emptied or {}) do
    if not points[bufnr] and vim.api.nvim_buf_is_valid(bufnr) then points[bufnr] = {} end
  end
  if not next(points) then return end
  broadcast(require("dap").sessions(), function(session) session:set_breakpoints(points) end)
end

---@param points table<integer, table[]>
---@return table<integer, boolean>
local function buffers(points)
  local held = {}
  for bufnr in pairs(points) do
    held[bufnr] = true
  end
  return held
end

---@param points table<integer, table[]>
---@return integer
local function count(points)
  local total = 0
  for _, per_buffer in pairs(points) do
    total = total + #per_buffer
  end
  return total
end

---@param points table<integer, table[]>
---@return table[]
local function serialise(points)
  local entries = {}
  for bufnr, list in pairs(points) do
    local file = vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) or ""
    if file ~= "" then
      for _, point in ipairs(list) do
        entries[#entries + 1] = {
          file = file,
          line = point.line,
          condition = point.condition,
          hit_condition = point.hitCondition,
          log_message = point.logMessage,
        }
      end
    end
  end
  return entries
end

function M.save()
  local path = M.store_path(vim.fn.getcwd())
  local entries = serialise(muted or require("dap.breakpoints").get())
  if #entries == 0 then
    vim.uv.fs_unlink(path)
    return
  end
  vim.fs.mkdir(store_dir(), { parents = true })
  pcall(vim.fn.writefile, { vim.json.encode(entries) }, path)
end

---@return integer restored
function M.load()
  local path = M.store_path(vim.fn.getcwd())
  if not vim.uv.fs_stat(path) then return 0 end

  local ok, decoded = pcall(function() return vim.json.decode(table.concat(vim.fn.readfile(path), "\n")) end)
  if not ok or type(decoded) ~= "table" then return 0 end

  local breakpoints = require "dap.breakpoints"
  local restored = 0
  for _, entry in ipairs(decoded) do
    if type(entry) == "table" and type(entry.file) == "string" and type(entry.line) == "number" then
      if vim.uv.fs_stat(entry.file) then
        local bufnr = vim.fn.bufadd(entry.file)
        vim.fn.bufload(bufnr)
        if entry.line <= vim.api.nvim_buf_line_count(bufnr) then
          breakpoints.set({
            condition = entry.condition,
            hit_condition = entry.hit_condition,
            log_message = entry.log_message,
          }, bufnr, entry.line)
          restored = restored + 1
        end
      end
    end
  end
  return restored
end

function M.forget()
  local path = M.store_path(vim.fn.getcwd())
  if not vim.uv.fs_stat(path) then return say "Nothing is stored for this project" end
  vim.uv.fs_unlink(path)
  say(("Forgot the stored breakpoints for %s"):format(vim.fn.fnamemodify(vim.fn.getcwd(), ":~")))
end

function M.toggle()
  require("dap").toggle_breakpoint()
  sync { [vim.api.nvim_get_current_buf()] = true }
  M.save()
end

function M.condition()
  vim.ui.input({ prompt = "Break when: " }, function(condition)
    if not condition or vim.trim(condition) == "" then return end
    require("dap").set_breakpoint(condition)
    sync()
    M.save()
  end)
end

--- A breakpoint that prints instead of stopping. A watch expression only re-reads
--- when execution stops, so watching a value that moves every frame means
--- stopping every frame; a logpoint leaves the program running.
function M.logpoint()
  vim.ui.input({ prompt = "Log message, {expression} is evaluated: " }, function(message)
    if not message or vim.trim(message) == "" then return end
    require("dap").set_breakpoint(nil, nil, message)
    sync()
    M.save()
  end)
end

function M.hit_condition()
  vim.ui.input({ prompt = "Break after how many hits: " }, function(hits)
    if not hits or vim.trim(hits) == "" then return end
    require("dap").set_breakpoint(nil, hits)
    sync()
    M.save()
  end)
end

function M.list() require("plugins.debug.ui").float "breakpoints" end

function M.toggle_mute()
  local breakpoints = require "dap.breakpoints"

  if muted then
    local restored = count(muted)
    for bufnr, points in pairs(muted) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        for _, point in ipairs(points) do
          breakpoints.set({
            condition = point.condition,
            hit_condition = point.hitCondition,
            log_message = point.logMessage,
          }, bufnr, point.line)
        end
      end
    end
    muted = nil
    sync()
    return say(("%d breakpoints are live again"):format(restored))
  end

  local points = breakpoints.get()
  local total = count(points)
  if total == 0 then return say "There are no breakpoints to mute" end

  muted = points
  breakpoints.clear()
  sync(buffers(points))
  say(("%d breakpoints muted -- the same key brings them back"):format(total), vim.log.levels.WARN)
end

function M.clear()
  local breakpoints = require "dap.breakpoints"
  local points = breakpoints.get()
  local total = count(points) + count(muted or {})
  if total == 0 then return say "There are no breakpoints to delete" end

  local emptied = buffers(points)
  -- Clearing while muted has to forget the muted set too, or the next unmute
  -- would resurrect what was just thrown away -- and the adapter is still holding
  -- those, since muting is the one thing that never told it.
  for bufnr in pairs(muted or {}) do
    emptied[bufnr] = true
  end
  muted = nil

  breakpoints.clear()
  sync(emptied)
  M.save()
  say(("%d breakpoints deleted"):format(total))
end

---@return boolean
function M.is_muted() return muted ~= nil end

---@return integer
function M.count() return count(muted or require("dap.breakpoints").get()) end

function M.setup()
  M.load()
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("plugins_debug_breakpoints", { clear = true }),
    callback = M.save,
  })
end

return M
