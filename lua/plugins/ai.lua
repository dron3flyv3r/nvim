-- `<Leader>a` — AI tools.
--
-- Three tools share the group and they answer different questions, so they get
-- keys by how often you reach for them rather than by first letter:
--
--   * Claude   -- `<Leader>aa` and the letters around it. A real editor
--                 integration (see `plugins/claude.lua`), so it gets the
--                 headline key and the context-pushing keys.
--   * Copilot  -- `<Leader>ac` / `<Leader>aC` / `<Leader>as`, unchanged. Two
--                 toggles and a status, which is all it needs.
--   * Codex    -- `<Leader>ax`, an alias for the `<Leader>tc` float.
--
-- Claude's own plugin ships a `keys` table that collides with all three Copilot
-- keys; `plugins/claude.lua` turns it off and the mappings are written out here
-- instead. Nothing outside `<Leader>a` is touched.
--
-- Copilot has two independent switches and they are worth keeping apart:
--   * auto-trigger  -- whether ghost text appears as you type. Buffer-local,
--                      so you can silence it in one file and keep it elsewhere.
--   * the client    -- whether Copilot runs at all. Global, and what you want
--                      when you're on a plane or in someone else's codebase.
---@type LazySpec
return {
  "AstroNvim/astrocore",
  ---@param opts AstroCoreOpts
  opts = function(_, opts)
    -- Guaranteed by `astrocore.lua`, which sets `mappings` in its static opts;
    -- `assert` says so to the type checker instead of nil-checking every line.
    local maps = assert(opts.mappings)
    local icon = "󱚝 "

    maps.n["<Leader>a"] = { desc = icon .. "AI" }

    maps.n["<Leader>ac"] = {
      function()
        require("copilot.suggestion").toggle_auto_trigger()
        -- `toggle_auto_trigger` flips this buffer-local flag; read it back so the
        -- message reflects reality rather than what we assume we just set.
        local on = vim.b.copilot_suggestion_auto_trigger
        vim.notify(
          "Copilot suggestions " .. (on and "enabled" or "disabled") .. " (this buffer)",
          vim.log.levels.INFO,
          { title = "Copilot" }
        )
      end,
      desc = "Toggle Copilot suggestions (buffer)",
    }

    maps.n["<Leader>aC"] = {
      function()
        require("copilot.command").toggle()
        vim.schedule(function()
          local off = require("copilot.client").is_disabled()
          vim.notify(
            "Copilot " .. (off and "disabled" or "enabled") .. " (global)",
            vim.log.levels.INFO,
            { title = "Copilot" }
          )
        end)
      end,
      desc = "Toggle Copilot entirely (global)",
    }

    maps.n["<Leader>as"] = { "<Cmd>Copilot status<CR>", desc = "Copilot status" }

    -- Codex already lives on `<Leader>tc`; this is an alias under the AI group.
    maps.n["<Leader>ax"] = { function() require("codex").toggle() end, desc = "Toggle Codex" }

    -- ── Claude ────────────────────────────────────────────────────────────
    --
    -- Every one of these is a `<Cmd>`, not a `require`, on purpose: the plugin
    -- is `cmd`-lazy, so the command name is what wakes it up. Calling into its
    -- Lua API here would load it at startup and start the server with it.
    maps.n["<Leader>aa"] = { "<Cmd>ClaudeCode<CR>", desc = "Toggle Claude" }
    maps.n["<Leader>af"] = { "<Cmd>ClaudeCodeFocus<CR>", desc = "Focus Claude" }
    -- `%` is the current file, expanded by the command itself.
    maps.n["<Leader>ab"] = { "<Cmd>ClaudeCodeAdd %<CR>", desc = "Add this buffer to Claude" }

    -- Session pickers. `--continue` picks up the last conversation in this
    -- directory; `--resume` asks which one.
    maps.n["<Leader>ar"] = { "<Cmd>ClaudeCode --resume<CR>", desc = "Resume a Claude session" }
    -- `n` for "continue" because `<Leader>aC` is Copilot's global toggle.
    maps.n["<Leader>an"] = { "<Cmd>ClaudeCode --continue<CR>", desc = "Continue the last Claude session" }
    maps.n["<Leader>am"] = { "<Cmd>ClaudeCodeSelectModel<CR>", desc = "Select Claude model" }
    maps.n["<Leader>aS"] = { "<Cmd>ClaudeCodeStatus<CR>", desc = "Claude connection status" }

    -- Accepting or rejecting an edit Claude has proposed, from either side of
    -- the diff. Upstream puts accept on `<Leader>aa`, which is the toggle here,
    -- so it moves to `y` -- next to `d` for deny, and the same yes/no shape as
    -- the answer you are actually giving.
    maps.n["<Leader>ay"] = { "<Cmd>ClaudeCodeDiffAccept<CR>", desc = "Accept Claude's diff" }
    maps.n["<Leader>ad"] = { "<Cmd>ClaudeCodeDiffDeny<CR>", desc = "Reject Claude's diff" }

    -- Send the selection. `<Leader>as` is free in visual mode -- Copilot's
    -- status is normal-mode only -- so this matches upstream where it can.
    --
    -- `maps.x` rather than `maps.v`: `v` also covers select mode, where typing
    -- a printable key is meant to replace the selection.
    maps.x = maps.x or {}
    maps.x["<Leader>as"] = { "<Cmd>ClaudeCodeSend<CR>", desc = "Send selection to Claude" }

    -- The same key on a file in the tree adds that file instead. Buffer-local
    -- via an autocmd rather than neo-tree's own `window.mappings`, so the
    -- pickers get it too without teaching each one separately.
    --
    -- `<Leader>` reaches these buffers at all only because AstroNvim disables
    -- neo-tree's default `<Space>` mapping (`toggle_node`).
    opts.autocmds = opts.autocmds or {}
    opts.autocmds.claude_tree_add = {
      {
        event = "FileType",
        pattern = { "neo-tree", "snacks_picker_list" },
        desc = "<Leader>as adds the file under the cursor to Claude's context",
        callback = function(args)
          vim.keymap.set("n", "<Leader>as", "<Cmd>ClaudeCodeTreeAdd<CR>", {
            buffer = args.buf,
            desc = "Add file to Claude",
          })
        end,
      },
    }
  end,
}
