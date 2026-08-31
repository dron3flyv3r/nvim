-- Claude Code, as an editor integration rather than a terminal you happen to
-- have open next to one.
--
-- ── WHY THIS PLUGIN AND NOT A TERMINAL WRAPPER ──────────────────────────────
--
-- `<Leader>ax` already opens Codex in a float, and that is all a wrapper does:
-- a shell in a window, which you feed by copying text into it. This one is a
-- pure-Lua reimplementation of the WebSocket/MCP protocol the official VS Code
-- and JetBrains extensions speak, so the CLI on the other end knows what the
-- editor is doing:
--
--   * the file you are in and the lines you have selected are tracked live, so
--     "explain this" needs no pasting;
--   * edits come back as a real Neovim diffsplit to accept or reject, not as a
--     patch printed into a terminal;
--   * you can push context at it deliberately -- this buffer, this selection,
--     or the file under the cursor in neo-tree.
--
-- It is the same `claude` binary either way (`~/.local/bin/claude`), so auth,
-- `CLAUDE.md` and settings are whatever they already are on the command line.
--
-- ── WHY THE UPSTREAM KEYS ARE OFF ───────────────────────────────────────────
--
-- Upstream ships its own `keys` table and it wants `<Leader>ac`, `<Leader>aC`
-- and `<Leader>as` -- which are Copilot's two toggles and Copilot status in
-- `plugins/ai.lua`. Rather than let a plugin spec quietly win that argument,
-- there is no `keys` here at all: every Claude mapping lives beside the other
-- AI keys in `ai.lua`, and Copilot keeps the keys it had.
--
-- ── WHY IT LOADS ON A COMMAND ───────────────────────────────────────────────
--
-- `auto_start` (default, left alone) brings up a WebSocket server on loopback
-- so the CLI has something to connect back to. That is not something to pay for
-- on every `nvim`, so the spec is `cmd`-lazy: the server starts the first time
-- you actually press a Claude key, and never in a session where you don't.
---@type LazySpec
return {
  "coder/claudecode.nvim",
  -- Already installed (AstroNvim v5 ships it); listed so load order is right
  -- when the terminal provider below reaches for it.
  dependencies = { "folke/snacks.nvim" },
  cmd = {
    "ClaudeCode",
    "ClaudeCodeFocus",
    "ClaudeCodeSelectModel",
    "ClaudeCodeAdd",
    "ClaudeCodeSend",
    "ClaudeCodeTreeAdd",
    "ClaudeCodeStatus",
    "ClaudeCodeStart",
    "ClaudeCodeStop",
    "ClaudeCodeOpen",
    "ClaudeCodeClose",
    "ClaudeCodeDiffAccept",
    "ClaudeCodeDiffDeny",
    "ClaudeCodeCloseAllDiffs",
  },
  opts = {
    terminal = {
      -- `auto` would pick snacks anyway; naming it means a future AstroNvim
      -- that stops shipping snacks fails loudly here instead of silently
      -- falling back to a plain `:terminal` split.
      provider = "snacks",
      split_side = "right",
      split_width_percentage = 0.30,
      -- NOTE: `focus_after_send` is left at its default (false), so sending a
      -- selection leaves the cursor in your code. `<Leader>af` walks over to
      -- the conversation when you want to type at it.
    },
    diff_opts = {
      -- Vertical: the same left/right shape `<Leader>gd` gives you for git, so
      -- reviewing Claude's edit reads like reviewing anyone else's.
      layout = "vertical",
      open_in_new_tab = false,
    },
  },
}
