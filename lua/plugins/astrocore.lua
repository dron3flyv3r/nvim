-- AstroCore: vim options, diagnostics, and the base mapping table.
-- Configuration documentation: `:h astrocore`
--
-- Most mappings live in the focused files next to this one (`danish-keys.lua`,
-- `navigation.lua`, `quickfix.lua`, `tasks.lua`, `ai.lua`), which all extend the
-- same `opts.mappings` table. This file holds only what has no better home.
---@type LazySpec
return {
  "AstroNvim/astrocore",
  ---@type AstroCoreOpts
  opts = {
    features = {
      large_buf = { size = 1024 * 256, lines = 10000 }, -- disable treesitter etc. above this
      autopairs = true,
      cmp = true,
      diagnostics = { virtual_text = true, virtual_lines = false }, -- startup state; `<Leader>ud` cycles it
      highlighturl = true,
      notifications = true,
    },

    -- Diagnostics. THIS IS THE ONLY PLACE THEY ARE CONFIGURED -- AstroCore feeds
    -- this table to `vim.diagnostic.config()`, so calling that function directly
    -- somewhere else (polish.lua used to) just makes two owners fighting.
    diagnostics = {
      -- Re-lint while you are still typing, rather than waiting for <Esc>.
      -- This is the "errors appear as I type" behaviour from VS Code.
      update_in_insert = true,

      -- Compact `● message` at the end of the offending line, for every line.
      virtual_text = {
        spacing = 2,
        prefix = "●",
        source = "if_many", -- name the server only when several are attached
      },

      -- ...and the full message rendered *underneath* the cursor's line only.
      -- Virtual text gets truncated at the window edge; long type errors from
      -- basedpyright and clangd are exactly the ones that need the room. This
      -- gives the detail where you're looking without a wall of text elsewhere.
      -- (Neovim 0.11+ feature.)
      virtual_lines = { current_line = true },

      underline = true,
      severity_sort = true, -- when a line has several, show the worst one
      float = { border = "rounded", source = true },
    },

    -- vim options
    options = {
      opt = { -- vim.opt.<key>
        relativenumber = true,
        number = true,
        spell = false,
        signcolumn = "yes",

        -- Wrap is OFF by default -- code is written to a column limit, and a
        -- wrapped buffer makes `æd`/`ød` land on lines that are not where the
        -- cursor appears to be. `<Leader>uw` (or `<A-z>`) turns it on for the
        -- current window; `wrap.lua` explains the rest and holds the toggle.
        --
        -- The three settings under it only take effect while wrap is on, which
        -- is why they can be set unconditionally here: they cost nothing in the
        -- default state and mean the toggle produces something readable rather
        -- than something technically wrapped.
        wrap = false,
        linebreak = true, -- break between words, not through the middle of an identifier
        breakindent = true, -- continuation keeps the indent of the line it belongs to
        breakindentopt = "shift:2", -- ...plus two, so a continuation cannot be mistaken for a new statement
        showbreak = "↳ ",
        scrolloff = 8, -- keep 8 lines visible above/below the cursor
        sidescrolloff = 8, -- keep 8 columns visible left/right of the cursor
      },
      g = { -- vim.g.<key>
        -- NOTE: `mapleader` / `maplocalleader` must be set before lazy loads;
        -- they live in `lua/lazy_setup.lua`.
      },
    },

    mappings = {
      n = {
        -- Buffer navigation by pair-jump. `æb` / `øb` on a Danish layout.
        ["]b"] = { function() require("astrocore.buffer").nav(vim.v.count1) end, desc = "Next buffer" },
        ["[b"] = { function() require("astrocore.buffer").nav(-vim.v.count1) end, desc = "Previous buffer" },

        ["<Leader>bd"] = {
          function()
            require("astroui.status.heirline").buffer_picker(
              function(bufnr) require("astrocore.buffer").close(bufnr) end
            )
          end,
          desc = "Close buffer from tabline",
        },
      },
    },
  },
}
