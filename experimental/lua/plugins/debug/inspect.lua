local M = {}

--- Inspect the value under the cursor, in a float you can walk into and expand.
function M.eval() require("dapui").eval(nil, { enter = true }) end

function M.evaluate()
  vim.ui.input({ prompt = "Expression: " }, function(expression)
    if expression and vim.trim(expression) ~= "" then require("dapui").eval(expression, { enter = true }) end
  end)
end

--- A watch expression is re-read every time execution stops, so it answers "what
--- is this now, and now" across successive hits. For something that moves every
--- frame, use a logpoint instead.
function M.watch()
  vim.ui.input({ prompt = "Watch expression: " }, function(expression)
    if not expression or vim.trim(expression) == "" then return end
    local ui = require "plugins.debug.ui"
    require("dapui").elements.watches.add(expression)
    -- Without the panel the expression would land in a window that is not on
    -- screen, and adding one would look like nothing happening.
    if not ui.panel_open() then ui.float "watches" end
  end)
end

-- `K` means "tell me about the thing under the cursor". While a session is
-- stopped the useful answer is the runtime value rather than the LSP's static
-- one, so the key is borrowed for the duration -- and the mapping that was there
-- before is put back verbatim, because lsp.lua installs its `K` buffer-locally
-- and simply deleting ours would leave the buffer with no hover at all.
local borrowed = {}

---@param buf integer
local function borrow(buf)
  if borrowed[buf] ~= nil or not vim.api.nvim_buf_is_valid(buf) then return end
  if vim.bo[buf].buftype ~= "" then return end

  vim.api.nvim_buf_call(buf, function()
    local previous = vim.fn.maparg("K", "n", false, true)
    borrowed[buf] = (previous and previous.buffer == 1) and previous or false
  end)
  vim.keymap.set("n", "K", M.eval, { buffer = buf, desc = "Evaluate under cursor" })
end

local function give_back()
  for buf, previous in pairs(borrowed) do
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.keymap.del, "n", "K", { buffer = buf })
      -- `mapset` restores into the current buffer, not the one the dictionary
      -- came from, so the restore has to happen inside that buffer.
      if previous then vim.api.nvim_buf_call(buf, function() pcall(vim.fn.mapset, previous) end) end
    end
  end
  borrowed = {}
end

local augroup = vim.api.nvim_create_augroup("plugins_debug_inspect", { clear = true })

function M.on_session_start()
  vim.api.nvim_clear_autocmds { group = augroup }
  vim.api.nvim_create_autocmd("BufEnter", {
    group = augroup,
    desc = "Borrow K for runtime evaluation while a debug session is live",
    callback = function(args) borrow(args.buf) end,
  })
  borrow(vim.api.nvim_get_current_buf())
end

function M.on_session_end()
  vim.api.nvim_clear_autocmds { group = augroup }
  give_back()
end

return M
