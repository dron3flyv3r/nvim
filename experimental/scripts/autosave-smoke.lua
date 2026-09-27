vim.opt.runtimepath:prepend(vim.fn.getcwd())

local dir = vim.fn.tempname()
local path = dir .. "/main.rs"
local other = dir .. "/other.rs"
local commit = dir .. "/.git/COMMIT_EDITMSG"

local function cleanup() vim.fs.rm(dir, { recursive = true, force = true }) end

local function on_disk(file, text) return vim.fn.readfile(file)[1]:find(text, 1, true) ~= nil end

local ok, err = xpcall(function()
  vim.fs.mkdir(dir .. "/.git", { parents = true })
  vim.fn.writefile({ "fn main() {}" }, path)
  vim.fn.writefile({ "fn other() {}" }, other)
  vim.fn.writefile({ "" }, commit)
  require "core.autocmds"

  vim.cmd.edit(vim.fn.fnameescape(path))
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "fn main() { let live = true; }" })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = bufnr })
  vim.wait(100)
  assert(not on_disk(path, "live"), "an edit alone reached disk")

  vim.cmd.edit(vim.fn.fnameescape(other))
  assert(vim.wait(500, function() return not vim.bo[bufnr].modified end), "leaving the buffer did not save it")
  assert(on_disk(path, "live"), "leave save did not reach disk")

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "fn main() { let hidden = true; }" })
  vim.api.nvim_exec_autocmds("FocusLost", {})
  assert(vim.wait(500, function() return not vim.bo[bufnr].modified end), "focus loss did not save a hidden buffer")
  assert(on_disk(path, "hidden"), "hidden save did not reach disk")

  require("core.autosave").suspend(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "fn main() { let held = true; }" })
  vim.api.nvim_exec_autocmds("FocusLost", {})
  vim.wait(100)
  assert(not on_disk(path, "held"), "suspended autosave reached disk")

  require("core.autosave").resume(bufnr)
  vim.api.nvim_exec_autocmds("FocusLost", {})
  assert(vim.wait(500, function() return not vim.bo[bufnr].modified end), "resumed save did not finish")

  vim.cmd.edit(vim.fn.fnameescape(commit))
  local commit_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(commit_buf, 0, -1, false, { "message" })
  vim.api.nvim_exec_autocmds("FocusLost", {})
  vim.wait(100)
  assert(vim.bo[commit_buf].modified, "a buffer under .git was written")

  vim.api.nvim_exec_autocmds("QuitPre", {})
  assert(not vim.o.autowriteall, "quit borrowed autowriteall past an ineligible buffer")
  vim.bo[commit_buf].modified = false
  vim.api.nvim_exec_autocmds("QuitPre", {})
  assert(vim.o.autowriteall and require("core.autosave").writing(), "quit did not borrow autowriteall")
  vim.wait(50)
  assert(not vim.o.autowriteall, "autowriteall outlived the quit")
end, debug.traceback)

cleanup()
if not ok then error(err) end

print "AUTOSAVE_SMOKE_OK"
vim.cmd "qa!"
