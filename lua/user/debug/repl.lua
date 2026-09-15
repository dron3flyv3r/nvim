-- Word and line deletion at the `dap>` prompt.
--
-- Neovim withholds `i_CTRL-W` and `i_CTRL-U` from prompt buffers: the exact
-- keystroke that deletes a word in any other buffer does nothing here, silently.
-- These reimplement both, bounded by the prompt so the `dap> ` itself is never
-- eaten -- which is presumably why the built-ins refuse in the first place.
local M = {}

---@return integer row, integer col, integer prompt width of the prompt in bytes
local function position()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  return row, col, #vim.fn.prompt_getprompt(vim.api.nvim_get_current_buf())
end

---@param row integer
---@param from integer
---@param to integer
local function cut(row, from, to)
  vim.api.nvim_buf_set_text(0, row - 1, from, row - 1, to, {})
  vim.api.nvim_win_set_cursor(0, { row, from })
end

--- Back over trailing space, then over one run of either word characters or
--- punctuation -- the same two-step `i_CTRL-W` performs elsewhere, so that
--- `_feet.position` gives up `position`, then `.`, then `_feet`.
function M.delete_word()
  local row, col, prompt = position()
  if col <= prompt then return end

  local typed = vim.api.nvim_get_current_line():sub(prompt + 1, col)
  local kept = typed:gsub("%s+$", "")
  kept = kept:match "^(.-)[%w_]+$" or kept:match "^(.-)%p+$" or ""
  cut(row, prompt + #kept, col)
end

--- Everything typed, leaving the prompt.
function M.delete_line()
  local row, col, prompt = position()
  if col > prompt then cut(row, prompt, col) end
end

local function claim(buf)
  vim.keymap.set("i", "<C-w>", M.delete_word, { buffer = buf, desc = "Delete word before cursor" })
  vim.keymap.set("i", "<C-u>", M.delete_line, { buffer = buf, desc = "Delete back to the prompt" })
end

function M.setup()
  vim.api.nvim_create_autocmd("FileType", {
    pattern = "dap-repl",
    group = vim.api.nvim_create_augroup("user_debug_repl", { clear = true }),
    desc = "Restore word and line deletion, which prompt buffers do not get",
    callback = function(args) claim(args.buf) end,
  })

  -- The REPL buffer outlives a `dapui.setup()` that runs a second time.
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[buf].filetype == "dap-repl" then claim(buf) end
  end
end

return M
