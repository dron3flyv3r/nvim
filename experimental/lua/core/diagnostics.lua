local M = {}

local severity = vim.diagnostic.severity

function M.setup()
  vim.diagnostic.config {
    severity_sort = true,
    underline = true,
    update_in_insert = false,
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

return M
