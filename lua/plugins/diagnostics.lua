---@type LazySpec
return {
  "AstroNvim/astrocore",
  ---@param opts AstroCoreOpts
  opts = function(_, opts)
    -- Guaranteed by `astrocore.lua`, which sets `mappings` in its static opts;
    -- `assert` says so to the type checker instead of nil-checking every line.
    local maps = assert(opts.mappings)
    local diagnostics = require "user.diagnostics"

    local float = { function() diagnostics.float() end, desc = "Hover diagnostics (press again to focus)" }
    maps.n["<Leader>ld"] = float
    maps.n["gl"] = float

    -- Every diagnostic, in the picker. `<Leader>lD` is AstroNvim's key for
    -- this and is repointed rather than left alone, so that it cannot end up
    -- as the one entry point that ignores the filter.
    local all = { function() diagnostics.picker() end, desc = "Search diagnostics (whole project)" }
    maps.n["<Leader>xx"] = all
    maps.n["<Leader>lD"] = all
    maps.n["<Leader>xX"] = {
      function() diagnostics.picker "buffer" end,
      desc = "Search diagnostics (this buffer)",
    }

    maps.n["<Leader>ue"] = { function() diagnostics.toggle() end, desc = "Toggle errors-only diagnostics" }

    -- `]d` / `[d` -- and therefore `æd` / `ød`, which remap onto them -- skip
    -- whatever the filter is hiding. A filter you can still walk into has not
    -- hidden anything.
    maps.n["]d"] = { function() diagnostics.jump(vim.v.count1) end, desc = "Next diagnostic" }
    maps.n["[d"] = { function() diagnostics.jump(-vim.v.count1) end, desc = "Previous diagnostic" }
  end,
}
