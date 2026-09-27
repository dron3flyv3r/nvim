local M = {}

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
  return bo.buftype == ""
    and bo.modifiable
    and not bo.readonly
    and not in_diff(bufnr)
    and bo.modified
    and name ~= ""
    and not name:find("://", 1, true)
    and not name:find("/.git/", 1, true)
end

local function write(bufnr)
  writing = true
  local ok, err = pcall(vim.api.nvim_buf_call, bufnr, function() vim.cmd "silent update" end)
  writing = false
  if not ok then vim.notify(err, vim.log.levels.WARN, { title = "Autosave" }) end
end

---@return boolean
function M.writing() return writing end

function M.flush()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if eligible(bufnr) then write(bufnr) end
  end
end

-- 'autowriteall' is what lets `:q!` still discard, which a QuitPre flush cannot
-- tell apart from `:q`; left on permanently it would also write on `:!` and
-- <C-^>, which the Rust watcher would then read as an explicit `:w`.
function M.on_quit()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    local bo = vim.bo[bufnr]
    if bo.modified and bo.buftype == "" and not bo.readonly and not eligible(bufnr) then return end
  end
  vim.o.autowriteall = true
  writing = true
  vim.schedule(function()
    vim.o.autowriteall = false
    writing = false
  end)
end

---@param bufnr integer
function M.suspend(bufnr) suspended[bufnr] = (suspended[bufnr] or 0) + 1 end

---@param bufnr integer
function M.resume(bufnr)
  local count = suspended[bufnr]
  if not count then return end
  suspended[bufnr] = count > 1 and count - 1 or nil
end

---@param bufnr integer
function M.forget(bufnr) suspended[bufnr] = nil end

return M
