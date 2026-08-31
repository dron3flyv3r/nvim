-- Danish (ISO) keyboard layout optimisations.
--
-- Vim's defaults assume a US layout. On a Danish keyboard the keys Vim leans on
-- hardest are the ones that cost an AltGr or a dead key:
--
--     [  ]   AltGr+8 / AltGr+9   -- the prefix for every pair-jump (]b ]d ]q ...)
--     {  }   AltGr+7 / AltGr+0   -- paragraph / block motion
--     $      AltGr+4             -- end of line
--     ^      dead key + space    -- first non-blank character
--
-- Meanwhile æ ø å sit on prime real estate (æ and ø are on the home row, right
-- under your ring and little finger) and mean nothing to Vim. So we trade:
--
--     ø -> [     Ø -> {     å -> $
--     æ -> ]     Æ -> }     Å -> ^
--
-- `remap = true` on the bracket keys is essential, not cosmetic: `]b`, `]d`,
-- `]g` and friends are themselves mappings, so a non-recursive `æ -> ]` would
-- send a literal `]` and nothing would fire.
--
-- Two things Danish makes *easier* than US, worth knowing: `<` and `>` are
-- unshifted on the key left of Z (so indenting is cheap), and `,` -- your
-- localleader -- is unshifted too.
---@type LazySpec
return {
  "AstroNvim/astrocore",
  ---@param opts AstroCoreOpts
  opts = function(_, opts)
    -- Guaranteed by `astrocore.lua`, which sets `mappings` in its static opts;
    -- `assert` says so to the type checker instead of nil-checking every line.
    local maps = assert(opts.mappings)

    -- Motion keys, applied in normal + visual + operator-pending so they work
    -- standalone (`åx`), after an operator (`då`) and inside a selection.
    local motions = {
      ["ø"] = { "[", "`[` prefix (Danish)", true },
      ["æ"] = { "]", "`]` prefix (Danish)", true },
      ["Ø"] = { "{", "Previous paragraph/block", false },
      ["Æ"] = { "}", "Next paragraph/block", false },
      ["å"] = { "$", "End of line", false },
      ["Å"] = { "^", "First non-blank character", false },
    }
    for lhs, spec in pairs(motions) do
      local rhs, desc, recursive = spec[1], spec[2], spec[3]
      for _, mode in ipairs { "n", "x", "o" } do
        maps[mode] = maps[mode] or {}
        maps[mode][lhs] = { rhs, desc = desc, remap = recursive }
      end
    end

    -- `|` and `\` (AstroNvim's split keys) are both AltGr on Danish. Keep them,
    -- but add leader alternatives that don't need a modifier at all.
    maps.n["<Leader>s"] = { desc = "󰓩 Split" }
    maps.n["<Leader>sv"] = { "<Cmd>vsplit<CR>", desc = "Vertical split" }
    maps.n["<Leader>sh"] = { "<Cmd>split<CR>", desc = "Horizontal split" }
    maps.n["<Leader>sc"] = { "<Cmd>close<CR>", desc = "Close split" }
    maps.n["<Leader>so"] = { "<Cmd>only<CR>", desc = "Close other splits" }

    -- F1 is additive; native `?` remains backward search.
    local function cheatsheet() require("cheatsheet").open() end
    maps.n["<F1>"] = { cheatsheet, desc = "Cheatsheet" }
    maps.x["<F1>"] = { cheatsheet, desc = "Cheatsheet" }
    maps.i["<F1>"] = {
      function()
        vim.cmd.stopinsert()
        cheatsheet()
      end,
      desc = "Cheatsheet",
    }
    maps.t["<F1>"] = {
      function()
        vim.cmd.stopinsert()
        vim.schedule(cheatsheet)
      end,
      desc = "Cheatsheet",
    }

    opts.commands = opts.commands or {}
    opts.commands.Cheatsheet = { cheatsheet, desc = "Open the navigation cheatsheet" }
  end,
}
