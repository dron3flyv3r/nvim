-- `<Leader>a` — AI tools.
--
-- Deliberately its own group so Claude and friends can move in later without
-- reshuffling keys: `<Leader>ac` is Copilot, `<Leader>ax` is Codex, and the
-- rest of the letter space is free.
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
  end,
}
