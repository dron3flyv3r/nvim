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
    vim.keymap.set("i", "<CR>", function()
      if vim.b.minipairs_disable or not filetypes[vim.bo.filetype] or not brace_own_line() then
        vim.api.nvim_feedkeys(require("mini.pairs").cr(), "in", false)
      end
    end, { desc = "MiniPairs <CR>, with the opening brace on its own line where a language asks" })
  end,
}
