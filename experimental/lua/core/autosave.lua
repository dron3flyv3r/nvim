local M = {}

---@class core.AutosaveConfig
---@field delay? integer

---@class core.AutosaveState
---@field generation integer
---@field timer uv.uv_timer_t

---@type table<string, core.AutosaveConfig>
local filetypes = {}
---@type table<integer, core.AutosaveState>
local states = {}
---@type table<integer, integer>
local suspended = {}
local writing = false

local function in_diff(bufnr)
  for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.wo[winid].diff then return true end
  end
  return false
end

local function eligible(bufnr)
  if suspended[bufnr] or not (vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr)) then
    return false
  end
  local bo = vim.bo[bufnr]
  local name = vim.api.nvim_buf_get_name(bufnr)
  return filetypes[bo.filetype] ~= nil
    and bo.buftype == ""
    and bo.modifiable
    and not bo.readonly
    and not in_diff(bufnr)
    and bo.modified
    and name ~= ""
    and not name:find("://", 1, true)
end

local function save(bufnr, generation)
  local state = states[bufnr]
  if not state or state.generation ~= generation or not eligible(bufnr) then return end
  writing = true
  local ok, err = pcall(vim.api.nvim_buf_call, bufnr, function() vim.cmd "silent update" end)
  writing = false
  if not ok then vim.notify(err, vim.log.levels.WARN, { title = "Autosave" }) end
end

---@return boolean
function M.writing() return writing end

---@param filetype string
---@param config? core.AutosaveConfig
function M.register(filetype, config)
  vim.validate("filetype", filetype, "string")
  config = config or {}
  vim.validate("delay", config.delay, "number", true)
  filetypes[filetype] = { delay = config.delay or 800 }
end

---@param bufnr integer
function M.changed(bufnr)
  if not eligible(bufnr) then return end
  local config = filetypes[vim.bo[bufnr].filetype]
  local state = states[bufnr]
  if not state then
    local timer = vim.uv.new_timer()
    if not timer then return end
    state = { generation = 0, timer = timer }
    states[bufnr] = state
  end
  state.generation = state.generation + 1
  local generation = state.generation
  state.timer:stop()
  state.timer:start(config.delay or 800, 0, function() vim.schedule(function() save(bufnr, generation) end) end)
end

---@param bufnr integer
function M.suspend(bufnr)
  suspended[bufnr] = (suspended[bufnr] or 0) + 1
  local state = states[bufnr]
  if state then state.timer:stop() end
end

---@param bufnr integer
function M.resume(bufnr)
  local count = suspended[bufnr]
  if not count then return end
  suspended[bufnr] = count > 1 and count - 1 or nil
end

---@param bufnr integer
function M.forget(bufnr)
  local state = states[bufnr]
  if state then
    state.timer:stop()
    state.timer:close()
    states[bufnr] = nil
  end
  suspended[bufnr] = nil
end

return M
