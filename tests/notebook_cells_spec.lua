local cells = require "user.integrations.notebook.cells"

local function same(actual, expected, label)
  assert(
    vim.deep_equal(actual, expected),
    ("%s: expected %s, got %s"):format(label, vim.inspect(expected), vim.inspect(actual))
  )
end

local previous = vim.api.nvim_get_current_buf()
local buffer = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buffer)
vim.api.nvim_buf_set_lines(buffer, 0, -1, false, {
  "preamble = true",
  "# %%",
  "answer = 42",
  "# %% [markdown]",
  "# Explanation",
  "#%%",
  "print(answer)",
})

same(cells.starts(buffer), { 2, 4, 6 }, "cell starts")
same({ cells.bounds(1, buffer) }, { 1, 1 }, "preamble bounds")
same({ cells.bounds(3, buffer) }, { 2, 3 }, "code cell bounds")
same({ cells.bounds(5, buffer) }, { 4, 5 }, "markdown cell bounds")
assert(cells.is_prose(4, buffer), "markdown marker should be prose")
assert(not cells.is_prose(2, buffer), "code marker should not be prose")

vim.api.nvim_set_current_buf(previous)
vim.api.nvim_buf_delete(buffer, { force = true })
