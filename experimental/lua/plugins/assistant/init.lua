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

---@param name string
---@param ... any
---@return fun()
local function guarded(name, ...)
  local args = { ... }
  return function()
    warn_about_review()
    require("plugins.assistant.agents")[name](unpack(args))
  end
end

require("core.session").register("agents", {
  save = function()
    local agents = package.loaded["plugins.assistant.agents"]
    return agents and agents.snapshot()
  end,
  restore = function(data) require("plugins.assistant.agents").restore(data) end,
})

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
    { "<Leader>aa", guarded "pick", desc = "Agents: switch to one, or start one" },
    { "<Leader>af", guarded "focus", desc = "Focus the current agent, or hide it" },
    { "<Leader>ac", guarded("start_like_current", "continue"), desc = "Continue the last agent session" },
    { "<Leader>ar", guarded("start_like_current", "resume"), desc = "Resume an agent session" },
    { "<Leader>ab", guarded "add_buffer", desc = "Add this buffer to the current agent" },
    { "<Leader>as", guarded "send", mode = { "n", "x" }, desc = "Send the selection, or the files here" },
    { "<Leader>ay", "<Cmd>ClaudeCodeDiffAccept<CR>", desc = "Accept Claude's diff" },
    { "<Leader>ad", "<Cmd>ClaudeCodeDiffDeny<CR>", desc = "Reject Claude's diff" },
  },
  opts = {
    -- The terminals are `agents.lua`'s; claudecode is only the server they share.
    terminal = { provider = "none" },
    diff_opts = { layout = "vertical", open_in_new_tab = false },
  },
}
