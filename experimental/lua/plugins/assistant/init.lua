local warned = false

-- A `pcall` so that deleting `lua/plugins/git` leaves this working, the same
-- shape as `roslyn.lua` reaching for the Unity root.
---@return string[]
local function held_by_review()
  local ok, held = pcall(function() return require("plugins.git.review").held() end)
  return ok and held or {}
end

-- Claude writes to disk; a review holds its buffers in memory until `q`. Once
-- per review, because which one you want is your call to make, not to re-read.
local function warn_about_review()
  local held = held_by_review()
  if #held == 0 then
    warned = false
    return
  end
  if warned then return end
  warned = true
  local subject = #held == 1 and "1 file" or ("%d files"):format(#held)
  vim.notify(
    ("A review is holding %s off disk. Claude edits the copy on disk, so its changes and the review's pending ones will not agree."):format(
      subject
    ),
    vim.log.levels.WARN,
    { title = "Claude" }
  )
end

---@param command string
---@return fun()
local function guarded(command)
  return function()
    warn_about_review()
    vim.cmd(command)
  end
end

---@type LazySpec
return {
  "coder/claudecode.nvim",
  dependencies = { "folke/snacks.nvim" },
  cmd = {
    "ClaudeCode",
    "ClaudeCodeAdd",
    "ClaudeCodeClose",
    "ClaudeCodeCloseAllDiffs",
    "ClaudeCodeDiffAccept",
    "ClaudeCodeDiffDeny",
    "ClaudeCodeFocus",
    "ClaudeCodeOpen",
    "ClaudeCodeSelectModel",
    "ClaudeCodeSend",
    "ClaudeCodeStart",
    "ClaudeCodeStatus",
    "ClaudeCodeStop",
    "ClaudeCodeTreeAdd",
  },
  keys = {
    { "<Leader>aa", guarded "ClaudeCode", desc = "Toggle Claude" },
    { "<Leader>af", guarded "ClaudeCodeFocus", desc = "Focus Claude" },
    { "<Leader>ac", guarded "ClaudeCode --continue", desc = "Continue the last Claude session" },
    { "<Leader>ar", guarded "ClaudeCode --resume", desc = "Resume a Claude session" },
    { "<Leader>ab", guarded "ClaudeCodeAdd %", desc = "Add this buffer to Claude" },
    -- `ClaudeCodeSend` dispatches on filetype itself, so one key covers the
    -- picker and the selection both. The old config bound a second, needless one.
    { "<Leader>as", guarded "ClaudeCodeSend", mode = { "n", "x" }, desc = "Send the selection, or the file here" },
    { "<Leader>ay", "<Cmd>ClaudeCodeDiffAccept<CR>", desc = "Accept Claude's diff" },
    { "<Leader>ad", "<Cmd>ClaudeCodeDiffDeny<CR>", desc = "Reject Claude's diff" },
  },
  opts = {
    -- Stated rather than left to `auto`, which probes with `require`.
    terminal = { provider = "snacks", split_side = "right", split_width_percentage = 0.30 },
    diff_opts = { layout = "vertical", open_in_new_tab = false },
  },
}
