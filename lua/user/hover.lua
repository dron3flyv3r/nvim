-- A readable LSP documentation window.
--
-- Servers decide which documentation and type context they return.  This only
-- controls how that answer is presented: wide enough for Rust signatures,
-- tall enough for doc comments, and still bounded to leave the source visible.
local M = {}

function M.open()
  local max_width = math.min(math.max(1, vim.o.columns - 8), math.max(50, math.floor(vim.o.columns * 0.82)))
  local max_height = math.min(math.max(1, vim.o.lines - 6), math.max(10, math.floor(vim.o.lines * 0.75)))

  vim.lsp.buf.hover {
    border = "rounded",
    title = " Documentation ",
    title_pos = "center",
    max_width = max_width,
    max_height = max_height,
    wrap = true,
    focus = true,
  }
end

return M
