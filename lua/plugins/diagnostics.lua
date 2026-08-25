-- The `<Leader>x` "problems" keys, and the errors-only filter.
--
-- The behaviour lives in `lua/user/diagnostics.lua`, which explains itself.
-- This file is the key map, and the reason it is a separate file from
-- `quickfix.lua` is that the two answer different questions:
--
--     <Leader>xd / xe / xb    put diagnostics in the QUICKFIX list, to walk
--                             them one at a time with æq, or to run :cdo over
--     <Leader>xx / xX         SHOW them, in the picker, with a preview
--
-- Both are worth having. The quickfix list is a work queue; the picker is a
-- way of looking. VS Code's Problems panel is the second one, which is the one
-- that was missing.
---@type LazySpec
return {
  "AstroNvim/astrocore",
  ---@param opts AstroCoreOpts
  opts = function(_, opts)
    -- Guaranteed by `astrocore.lua`, which sets `mappings` in its static opts;
    -- `assert` says so to the type checker instead of nil-checking every line.
    local maps = assert(opts.mappings)
    local diagnostics = require "user.diagnostics"

    -- The error under the cursor. Same two keys AstroNvim already uses, so
    -- nothing has to be relearned -- but focusable, so a message wider than
    -- the window can be scrolled and copied instead of just ending in `...`.
    -- Press once to show, again to step inside, again to come back.
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

    -- Errors only, on/off. `<Leader>ud` (all diagnostics off) and `<Leader>uv`
    -- (virtual text off) are the neighbouring AstroNvim toggles; this is the
    -- one in between, for when the code is fine and basedpyright merely has
    -- opinions about it.
    maps.n["<Leader>ue"] = { function() diagnostics.toggle() end, desc = "Toggle errors-only diagnostics" }

    -- `]d` / `[d` -- and therefore `æd` / `ød`, which remap onto them -- skip
    -- whatever the filter is hiding. A filter you can still walk into has not
    -- hidden anything.
    maps.n["]d"] = { function() diagnostics.jump(vim.v.count1) end, desc = "Next diagnostic" }
    maps.n["[d"] = { function() diagnostics.jump(-vim.v.count1) end, desc = "Previous diagnostic" }
  end,
}
