---@param line string
---@param col integer
---@return string? prefix, string? suffix
local function brace_split(line, col)
  if line:sub(col, col + 1) ~= "{}" then return end
  local prefix = line:sub(1, col - 1)
  if not prefix:find "%S" then return end
  return prefix, line:sub(col + 2)
end

local function brace_own_line()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local prefix, suffix = brace_split(vim.api.nvim_get_current_line(), col)
  if not prefix then return false end
  local indent = prefix:match "^%s*"
  local step = vim.bo.expandtab and (" "):rep(vim.fn.shiftwidth()) or "\t"
  vim.api.nvim_buf_set_lines(0, row - 1, row, true, {
    (prefix:gsub("%s+$", "")),
    indent .. "{",
    indent .. step,
    indent .. "}" .. suffix,
  })
  vim.api.nvim_win_set_cursor(0, { row + 2, #indent + #step })
  return true
end

local BEFORE_WORD = "[%w%%%'%[%\"%.%`%$]"

---@param before string
---@param quote string
---@return boolean
local function closes_open_quote(before, quote)
  local count = 0
  for i = 1, #before do
    if before:sub(i, i) == quote and before:sub(i - 1, i - 1) ~= "\\" then count = count + 1 end
  end
  return count % 2 == 1
end

---@param after string
---@param open string
---@param close string
---@return boolean
local function has_unmatched_close(after, open, close)
  local depth = 0
  for char in after:gmatch "." do
    if char == open then
      depth = depth + 1
    elseif char == close then
      if depth == 0 then return true end
      depth = depth - 1
    end
  end
  return false
end

---@param row integer 0-based
---@param col integer 0-based
---@return boolean
local function inside_string(row, col)
  local ok, node = pcall(vim.treesitter.get_node, { pos = { row, col }, ignore_injections = false })
  while ok and node do
    local kind = node:type()
    if kind:find "interpolation" or kind:find "substitution" then return false end
    if kind:find "string" then
      local sr, sc, er, ec = node:range()
      return (sr < row or sr == row and sc < col) and (row < er or row == er and col < ec)
    end
    node = node:parent()
  end
  return false
end

---@param pair string
---@return boolean
local function should_pair(pair)
  local open, close = pair:sub(1, 1), pair:sub(2, 2)
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local line = vim.api.nvim_get_current_line()
  local before, after = line:sub(1, col), line:sub(col + 1)
  if after:sub(1, 1):find(BEFORE_WORD) then return false end
  if open == close and closes_open_quote(before, open) then return false end
  if open ~= close and has_unmatched_close(after, open, close) then return false end
  return not inside_string(row - 1, col)
end

local function look_before_pairing()
  local mini = require "mini.pairs"
  local open = mini.open
  mini.open = function(pair, neigh_pattern)
    if vim.fn.mode() == "c" or should_pair(pair) then return open(pair, neigh_pattern) end
    return pair:sub(1, 1)
  end
end

---@type LazySpec
return {
  "echasnovski/mini.pairs",
  version = "*",
  event = "InsertEnter",
  -- The FileType handler is registered here rather than in `config` because the
  -- picker sets its filetype before the first InsertEnter loads the plugin.
  init = function()
    vim.api.nvim_create_autocmd("FileType", {
      group = vim.api.nvim_create_augroup("plugins_pairs", {}),
      pattern = { "snacks_picker_input", "snacks_input", "core_replace_input" },
      callback = function(args) vim.b[args.buf].minipairs_disable = true end,
      desc = "No pairing in a prompt, where an unclosed bracket is a search term",
    })
  end,
  opts = {
    mappings = {
      ["'"] = false,
      ["`"] = false,
    },
    ---@type table<string, boolean>
    brace_own_line = {},
  },
  config = function(_, opts)
    local filetypes = opts.brace_own_line
    opts.brace_own_line = nil
    require("mini.pairs").setup(opts)
    look_before_pairing()
    vim.keymap.set("i", "<CR>", function()
      if vim.b.minipairs_disable or not filetypes[vim.bo.filetype] or not brace_own_line() then
        vim.api.nvim_feedkeys(require("mini.pairs").cr(), "in", false)
      end
    end, { desc = "MiniPairs <CR>, with the opening brace on its own line where a language asks" })
  end,
}
