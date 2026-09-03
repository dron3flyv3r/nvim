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

      virtual_lines = { current_line = true },

      underline = true,
      severity_sort = true, -- when a line has several, show the worst one
      float = { border = "rounded", source = true },
    },

    -- vim options
    options = {
      opt = { -- vim.opt.<key>
        -- The shell used by `:terminal`, `:!`, and plugins that defer to
        -- Neovim's shell option. Fish is installed system-wide on this machine;
        -- its command flag is the same `-c` Neovim already uses on Unix.
        shell = "/usr/bin/fish",
        relativenumber = true,
        number = true,
        spell = false,
        signcolumn = "yes",

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

    autocmds = {
      expire_stale_lsp_progress = {
        {
          event = "LspProgress",
          desc = "Remove abandoned LSP progress from the statusline",
          callback = function(event) require("user.lsp_progress").expire(event.data, 15000) end,
        },
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
