vim.opt.runtimepath:prepend(vim.fn.getcwd())

local path = vim.fn.tempname() .. ".rs"

local function cleanup() pcall(vim.uv.fs_unlink, path) end

local ok, err = xpcall(function()
  vim.fn.writefile({ "fn main() {}" }, path)
  require("core.autosave").register("rust", { delay = 20 })
  require "core.autocmds"

  vim.cmd.edit(vim.fn.fnameescape(path))
  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "rust"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "fn main() { let live = true; }" })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = bufnr })
  assert(vim.wait(500, function() return not vim.bo[bufnr].modified end), "idle save did not finish")
  assert(vim.fn.readfile(path)[1]:find("live", 1, true), "idle save did not reach disk")

  require("core.autosave").suspend(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "fn main() { let held = true; }" })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = bufnr })
  vim.wait(100)
  assert(not vim.fn.readfile(path)[1]:find("held", 1, true), "suspended autosave reached disk")

  require("core.autosave").resume(bufnr)
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = bufnr })
  assert(vim.wait(500, function() return not vim.bo[bufnr].modified end), "resumed save did not finish")
  assert(vim.fn.readfile(path)[1]:find("held", 1, true), "resumed save did not reach disk")
end, debug.traceback)

if not ok then
  cleanup()
  error(err)
end

vim.uv.fs_unlink(path)
print "AUTOSAVE_SMOKE_OK"
vim.cmd "qa!"
