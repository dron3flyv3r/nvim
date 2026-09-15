-- Identifiers read off the source, for the two places that need candidates when
-- there is no paused process to ask: a conditional breakpoint set before
-- anything is running, and the REPL while the game is still going.
local M = {}

local KEYWORDS = {
  -- Enough of C#, Rust and C++ that the list does not offer `return` as though
  -- it were a variable.
  ["if"] = true,
  ["else"] = true,
  ["for"] = true,
  ["foreach"] = true,
  ["while"] = true,
  ["return"] = true,
  ["var"] = true,
  ["let"] = true,
  ["mut"] = true,
  ["new"] = true,
  ["void"] = true,
  ["public"] = true,
  ["private"] = true,
  ["protected"] = true,
  ["static"] = true,
  ["readonly"] = true,
  ["const"] = true,
  ["class"] = true,
  ["struct"] = true,
  ["enum"] = true,
  ["fn"] = true,
  ["pub"] = true,
  ["impl"] = true,
  ["match"] = true,
  ["true"] = true,
  ["false"] = true,
  ["null"] = true,
  ["None"] = true,
  ["Some"] = true,
}

--- The function the cursor is in, as a line range, or the whole buffer when
--- treesitter cannot say.
---@param bufnr integer
---@return integer first, integer last
local function enclosing_range(bufnr)
  if bufnr ~= vim.api.nvim_get_current_buf() then return 0, -1 end

  local node = vim.F.npcall(vim.treesitter.get_node)
  while node do
    local kind = node:type()
    if kind:find "function" or kind:find "method" or kind:find "declaration" then
      local srow, _, erow = node:range()
      return srow, erow + 1
    end
    node = node:parent()
  end
  return 0, -1
end

---@param bufnr integer
---@return string[]
function M.near(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return {} end
  local first, last = enclosing_range(bufnr)

  local seen, names = {}, {}
  for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, first, last, false)) do
    for word in line:gmatch "[%a_][%w_]*" do
      if not KEYWORDS[word] and not seen[word] then
        seen[word] = true
        table.insert(names, word)
      end
    end
  end
  return names
end

--- The file the REPL is standing in for: the debugger's own windows are not it.
---@return integer|nil bufnr
function M.source_buffer()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].buftype == "" and vim.api.nvim_buf_get_name(buf) ~= "" then return buf end
  end
end

return M
