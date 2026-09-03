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
