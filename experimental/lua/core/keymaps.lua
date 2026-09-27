local actions = require "core.actions"
local map = vim.keymap.set

map("n", "<Leader>r", actions.pick, { desc = "Actions available here" })
map("n", "<Leader>R", actions.repeat_last, { desc = "Repeat the last action" })

local motions = {
  ["æ"] = { "[", "`[` prefix (Danish)", true },
  ["ø"] = { "]", "`]` prefix (Danish)", true },
  ["Æ"] = { "{", "Previous paragraph", false },
  ["Ø"] = { "}", "Next paragraph", false },
  ["å"] = { "$", "End of line", false },
  ["Å"] = { "^", "First non-blank character", false },
}
for lhs, spec in pairs(motions) do
  local rhs, desc, recursive = spec[1], spec[2], spec[3]
  map({ "n", "x", "o" }, lhs, rhs, { desc = desc, remap = recursive })
end

map("n", "<Leader>w", "<Cmd>write<CR>", { desc = "Write" })

local ESCAPE_WINDOW_NS = 200e6
local escape_pending
-- A plain `inoremap jj <Esc>` holds back every `j` for 'timeoutlen'; this
-- inserts it at once and takes it back if the second key follows in time.
for _, key in ipairs { "j", "k" } do
  map("i", key, function()
    local now = vim.uv.hrtime()
    local row, col = unpack(vim.api.nvim_win_get_cursor(0))
    local bufnr = vim.api.nvim_get_current_buf()
    local previous = escape_pending
    escape_pending = { bufnr = bufnr, row = row, col = col + 1, time = now }
    if
      previous
      and previous.bufnr == bufnr
      and previous.row == row
      and previous.col == col
      and now - previous.time < ESCAPE_WINDOW_NS
    then
      escape_pending = nil
      return "<BS><Esc>"
    end
    return key
  end, { expr = true, desc = "Insert " .. key .. ", or leave insert mode after j/k" })
end

-- <C-l> is taken for window navigation below, and it was the default way to
-- clear multicursors (|mcursor-clear|). Clearing the namespace is the
-- documented equivalent.
map("n", "<Esc>", function()
  vim.cmd.nohlsearch()
  vim.api.nvim_buf_clear_namespace(0, vim.api.nvim_create_namespace "nvim.multicursor", 0, -1)
end, { desc = "Clear search highlight and multicursors" })

map("n", "grn", function() require("core.rename").start() end, { desc = "Rename with a live preview" })

map("n", "<Leader>uv", function() require("core.diagnostics").toggle_all() end, { desc = "Inline diagnostics scope" })

map("n", "<Leader>q", function() require("core.macros").pick() end, { desc = "Macros" })

map("t", "<Esc><Esc>", "<C-\\><C-n>", { desc = "Leave terminal mode" })
map("n", "<Leader>t", function() require("core.terminal").toggle() end, { desc = "Toggle terminal" })

for key, direction in pairs { h = "h", j = "j", k = "k", l = "l" } do
  map("n", "<C-" .. key .. ">", "<C-w>" .. direction, { desc = "Window " .. direction })
  map("t", "<C-" .. key .. ">", "<C-\\><C-n><C-w>" .. direction, { desc = "Window " .. direction })
end

-- <Cmd> rather than <C-w>+ and friends: it works unchanged from terminal mode,
-- where <C-w> is input to the process, and it reaches a winfixheight pane.
for key, cmd in pairs {
  Up = "resize +2",
  Down = "resize -2",
  Left = "vertical resize -2",
  Right = "vertical resize +2",
} do
  map({ "n", "t" }, "<C-" .. key .. ">", "<Cmd>" .. cmd .. "<CR>", { desc = "Resize window " .. key:lower() })
end

map("x", "<", "<gv", { desc = "Outdent and keep selection" })
map("x", ">", ">gv", { desc = "Indent and keep selection" })
