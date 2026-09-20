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

-- `|` and `\` both need AltGr on a Danish layout, so splits get a leader path too.
map("n", "<Leader>wv", "<Cmd>vsplit<CR>", { desc = "Vertical split" })
map("n", "<Leader>wh", "<Cmd>split<CR>", { desc = "Horizontal split" })
map("n", "<Leader>wc", "<Cmd>close<CR>", { desc = "Close window" })
map("n", "<Leader>wo", "<Cmd>only<CR>", { desc = "Close other windows" })

-- <C-l> is taken for window navigation below, and it was the default way to
-- clear multicursors (|mcursor-clear|). Clearing the namespace is the
-- documented equivalent.
map("n", "<Esc>", function()
  vim.cmd.nohlsearch()
  vim.api.nvim_buf_clear_namespace(0, vim.api.nvim_create_namespace "nvim.multicursor", 0, -1)
end, { desc = "Clear search highlight and multicursors" })

map("t", "<Esc><Esc>", "<C-\\><C-n>", { desc = "Leave terminal mode" })

for key, direction in pairs { h = "h", j = "j", k = "k", l = "l" } do
  map("n", "<C-" .. key .. ">", "<C-w>" .. direction, { desc = "Window " .. direction })
  map("t", "<C-" .. key .. ">", "<C-\\><C-n><C-w>" .. direction, { desc = "Window " .. direction })
end

map("x", "<", "<gv", { desc = "Outdent and keep selection" })
map("x", ">", ">gv", { desc = "Indent and keep selection" })
