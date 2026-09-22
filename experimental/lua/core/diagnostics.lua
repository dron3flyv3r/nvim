local M = {}

local severity = vim.diagnostic.severity

local insert_bufnr, insert_line = -1, -1

function M.setup()
  vim.diagnostic.config {
    severity_sort = true,
    underline = true,
    update_in_insert = true,
    signs = {
      text = {
        [severity.ERROR] = "",
        [severity.WARN] = "",
        [severity.INFO] = "",
        [severity.HINT] = "",
      },
    },
    -- rustc and roslyn messages run to several lines, which end-of-line virtual
    -- text truncates; scoping the expansion to the cursor line is what keeps
    -- them whole without pushing the rest of the file off the screen.
    virtual_text = false,
    virtual_lines = { current_line = true },
    float = { source = "if_many" },
  }
end

--- Widens the inline expansion from the cursor's line to every line, and back.
function M.toggle_all()
  local current = vim.diagnostic.config().virtual_lines
  local cursor_only = type(current) == "table" and current.current_line == true
  vim.diagnostic.config { virtual_lines = { current_line = not cursor_only } }
  vim.notify(
    cursor_only and "Inline diagnostics: every line" or "Inline diagnostics: cursor line",
    vim.log.levels.INFO,
    { title = "Diagnostics" }
  )
end

--- `virtual_lines.current_line` renders from `CursorHold`, which never fires in
--- insert mode, so the block stays under the line it was last published for
--- until the next publish moves it.
function M.on_insert_move(bufnr)
  local virtual_lines = vim.diagnostic.config().virtual_lines
  if type(virtual_lines) ~= "table" or virtual_lines.current_line ~= true then return end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  if bufnr == insert_bufnr and line == insert_line then return end
  insert_bufnr, insert_line = bufnr, line
  vim.diagnostic.show(nil, bufnr)
end

return M
