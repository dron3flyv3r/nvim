local M = {}

local remembered
local pending
local timer

local function store_path() return vim.fs.joinpath(vim.fn.stdpath "state" --[[@as string]], "colorscheme") end

---@return string?
local function read()
  local ok, lines = pcall(vim.fn.readfile, store_path())
  local name = ok and lines[1] or nil
  return name ~= "" and name or nil
end

local function flush()
  if timer then timer:stop() end
  timer = nil
  if pending and pending ~= remembered then
    remembered = pending
    local path = store_path()
    vim.fs.mkdir(vim.fs.dirname(path), { parents = true })
    pcall(vim.fn.writefile, { remembered }, path)
  end
  pending = nil
end

---@param name string
local function remember(name)
  pending = name
  if timer then timer:stop() end
  -- The picker previews by applying the scheme under the cursor, so these arrive
  -- one per keypress and only the last of them is a choice.
  timer = vim.defer_fn(flush, 300)
end

---@param default string
function M.setup(default)
  remembered = read()
  local name = remembered or default
  if not pcall(vim.cmd.colorscheme, name) then
    vim.notify(
      ("%s is not installed; falling back to %s."):format(name, default),
      vim.log.levels.WARN,
      { title = "colorscheme" }
    )
    -- The stored name is left alone, so reinstalling it restores the choice.
    vim.cmd.colorscheme(default)
  end

  local group = vim.api.nvim_create_augroup("core_colorscheme", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function(args) remember(args.match) end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = flush })
end

return M
