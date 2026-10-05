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

-- <C-l> is taken for window navigation below, and it was the default way to
-- clear multicursors (|mcursor-clear|). Clearing the namespace is the
-- documented equivalent.
map("n", "<Esc>", function()
  vim.cmd.nohlsearch()
  vim.api.nvim_buf_clear_namespace(0, vim.api.nvim_create_namespace "nvim.multicursor", 0, -1)
end, { desc = "Clear search highlight and multicursors" })

map("n", "grn", function() require("core.rename").start() end, { desc = "Rename with a live preview" })

map("n", "<Leader>uv", function() require("core.diagnostics").toggle_all() end, { desc = "Inline diagnostics scope" })
map("n", "<Leader>ue", function() require("core.diagnostics").toggle_errors_only() end, { desc = "Errors only" })

map("i", "<M-]>", function() vim.lsp.inline_completion.select { count = 1 } end, { desc = "Next inline suggestion" })
map("i", "<M-[>", function() vim.lsp.inline_completion.select { count = -1 } end, { desc = "Previous inline suggestion" })

map("n", "<Leader>q", function() require("core.macros").pick() end, { desc = "Macros" })

map({ "n", "x" }, "<Leader>sf", function() require("core.replace").open "file" end, { desc = "Replace in file" })
map({ "n", "x" }, "<Leader>sp", function() require("core.replace").open "project" end, { desc = "Replace in project" })

local ESCAPE_WINDOW_NS = 200 * 1e6
local typed_keys, escape_armed_at, escape_armed_count = 0, nil, 0
vim.on_key(function(_, typed)
  if typed ~= "" then typed_keys = typed_keys + 1 end
end, vim.api.nvim_create_namespace "core_escape")

---@param key string
local function escape_or(key)
  return function()
    local now = vim.uv.hrtime()
    if escape_armed_at and typed_keys == escape_armed_count + 1 and now - escape_armed_at < ESCAPE_WINDOW_NS then
      escape_armed_at = nil
      -- Not <Esc>: the <Leader>r menu binds insert-mode <Esc> to cancel, and jj there should reach the list.
      return "<BS><C-\\><C-n>"
    end
    escape_armed_at, escape_armed_count = now, typed_keys
    return key
  end
end
for _, key in ipairs { "j", "k" } do
  map({ "i", "c", "t" }, key, escape_or(key), { expr = true, desc = "Type " .. key .. ", or leave the mode after j/k" })
end

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
