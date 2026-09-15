-- The debugger lives under `<Leader>d`, one letter per action, alongside the
-- function keys AstroNvim binds for the things done often enough to be reflexes.
-- `K` answers "what is this worth right now" while a session is live.
local M = {}

local exception_filters = {}

local function dap() return require "dap" end
local function dapui() return require "dapui" end

-- The panels are meant to mirror the session lifecycle, but nvim-dap only
-- dispatches `event_terminated`/`event_exited` when the *adapter* chooses to
-- send them, and `dap.close()` sends nothing at all. Every stop path therefore
-- closes the UI itself rather than trusting an event that may never arrive.
function M.close_ui() dapui().close() end

function M.toggle_ui() dapui().toggle() end

--- The one way out. `terminate` asks the adapter to end the session, `close`
--- hangs up on it; the difference only mattered when both had a key, and a
--- debugger that is sometimes only half stopped is worse than either.
function M.stop()
  if dap().session() then dap().terminate() end
  dap().close()
  M.close_ui()
end

function M.restart()
  if not dap().session() then
    return vim.notify("No active debug session to restart", vim.log.levels.INFO, { title = "Debug" })
  end
  dap().restart()
end

function M.conditional_breakpoint() require("user.debug.condition").set() end

--- A breakpoint that prints instead of stopping. This is how you watch a value
--- change across a run: a watch expression only re-reads when execution stops,
--- so watching something that moves every frame means stopping every frame. A
--- logpoint leaves the game running and writes a line each time it is passed.
function M.logpoint()
  vim.ui.input({ prompt = "Log message, {expression} is evaluated: " }, function(message)
    if message and vim.trim(message) ~= "" then dap().set_breakpoint(nil, nil, message) end
  end)
end

function M.breakpoints() require("user.debug.breakpoints").list() end

function M.mute_breakpoints() require("user.debug.breakpoints").toggle_mute() end

function M.clear_breakpoints() require("user.debug.breakpoints").clear() end

function M.exceptions()
  vim.ui.input(
    { prompt = "Exception filters (comma-separated; empty clears): ", default = table.concat(exception_filters, ",") },
    function(value)
      exception_filters = {}
      for filter in (value or ""):gmatch "[^,%s]+" do
        table.insert(exception_filters, filter)
      end
      dap().set_exception_breakpoints(exception_filters)
    end
  )
end

--- The watch list, for the layouts that do not carry one.
function M.watches() dapui().float_element("watches", { enter = true, position = "center", width = 80, height = 12 }) end

--- A watch expression is re-read every time execution stops, so it answers
--- "what is this now, and now" across successive breakpoint hits. To follow
--- something that moves every frame, use a logpoint instead -- watching it would
--- mean stopping at every frame.
function M.watch()
  vim.ui.input({ prompt = "Watch expression: " }, function(expression)
    if not expression or vim.trim(expression) == "" then return end
    dapui().elements.watches.add(expression)
    -- The dock drops its watch column on a narrow terminal. Without this the
    -- expression would land in a pane that is not on screen, and adding one
    -- would look like nothing happening.
    if not require("user.debug.ui").shows "watches" then M.watches() end
  end)
end

--- Inspect the value under the cursor, in a float you can walk into and expand.
function M.eval() dapui().eval(nil, { enter = true }) end

--- Inspect something that is not under the cursor.
function M.evaluate()
  vim.ui.input({ prompt = "Expression: " }, function(expression)
    if expression and vim.trim(expression) ~= "" then dapui().eval(expression, { enter = true }) end
  end)
end

-- `K` means "tell me about the thing under the cursor". While a session is
-- stopped the useful answer is the runtime value rather than the LSP's static
-- one, so the key is borrowed for the duration -- and the mapping that was there
-- before is put back verbatim, because the LSP installs its `K` buffer-locally
-- and simply deleting ours would leave the buffer with no hover at all.
local borrowed = {}

local function borrow_eval_key(buf)
  if borrowed[buf] ~= nil or not vim.api.nvim_buf_is_valid(buf) then return end
  if vim.bo[buf].buftype ~= "" then return end

  vim.api.nvim_buf_call(buf, function()
    local previous = vim.fn.maparg("K", "n", false, true)
    borrowed[buf] = (previous and previous.buffer == 1) and previous or false
  end)
  vim.keymap.set("n", "K", M.eval, { buffer = buf, desc = "Evaluate under cursor" })
end

local function return_eval_keys()
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

local augroup = vim.api.nvim_create_augroup("user_debug_session", { clear = true })

function M.on_session_start()
  vim.api.nvim_clear_autocmds { group = augroup }
  vim.api.nvim_create_autocmd("BufEnter", {
    group = augroup,
    desc = "Borrow K for runtime evaluation while a debug session is live",
    callback = function(args) borrow_eval_key(args.buf) end,
  })
  borrow_eval_key(vim.api.nvim_get_current_buf())
end

function M.on_session_end()
  vim.api.nvim_clear_autocmds { group = augroup }
  return_eval_keys()
end

--- Start a session for whatever this buffer is. Unity and Rust both have an
--- entry point that knows more than `dap.continue()` does -- which editor to
--- attach to, which target to build first -- so they are asked directly.
function M.start()
  if require("user.integrations.unity").root(0) then return require("user.integrations.unity.dap").attach() end

  if vim.bo.filetype == "rust" and pcall(require, "rustaceanvim.config") then
    -- rustaceanvim builds the crate and derives the launch configuration from
    -- cargo's own metadata; a hand-written config would only re-guess it.
    return vim.cmd.RustLsp "debuggables"
  end

  dap().continue()
end

return M
