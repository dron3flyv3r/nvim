-- Soft wrap: the toggle, and making a wrapped buffer navigable.
--
-- WHY OFF BY DEFAULT. Code has a column limit already, so wrapping mostly
-- reports that somebody exceeded it. The lines you actually want wrapped are
-- the long ones -- a roslyn type error in a comment, a JSON blob, a prose
-- paragraph in a markdown file -- and those are a per-buffer decision, not a
-- global one. `wrap` is window-local, so the toggle is too: turning it on for
-- the file you are reading leaves every other window alone.
--
-- WHAT THE OPTIONS DO. `linebreak`, `breakindent`, `breakindentopt` and
-- `showbreak` are set in `astrocore.lua` next to `wrap` itself. Without them a
-- wrapped buffer breaks in the middle of `GetComponent` and restarts the
-- continuation at column zero, which is why "wrap" has a reputation among
-- people who have only ever tried `:set wrap`.
--
-- WHY `j` AND `k` ARE MAPPED. With wrap on, one wrapped line is one `j`: a
-- 300-character line is a single keystroke and the cursor appears to teleport.
-- `gj` / `gk` move by *screen* line, which is what the buffer looks like it is
-- doing. The mapping is an `expr` that hands back plain `j` whenever wrap is
-- off, so in the default state this is exactly Vim's own behaviour -- and it is
-- deliberately not mapped in operator-pending mode, because `dj` must stay a
-- two-whole-lines delete rather than deleting to the middle of one.
--
-- A count also means real lines: `5j` after reading `5` off the relative number
-- column has to land on that line, and the number column counts buffer lines.
---@type LazySpec
return {
  "AstroNvim/astrocore",
  ---@param opts AstroCoreOpts
  opts = function(_, opts)
    -- Guaranteed by `astrocore.lua`, which sets `mappings` in its static opts;
    -- `assert` says so to the type checker instead of nil-checking every line.
    local maps = assert(opts.mappings)

    -- `<Leader>uw` is AstroNvim's and stays. `<A-z>` is the same toggle on the
    -- key VS Code uses for it, including from insert mode -- the point of a
    -- modifier key here is not needing to leave insert to read the line you are
    -- in the middle of writing.
    local function toggle() require("astrocore.toggles").wrap() end
    for _, mode in ipairs { "n", "x", "i" } do
      maps[mode] = maps[mode] or {}
      maps[mode]["<A-z>"] = { toggle, desc = "Toggle wrap" }
    end

    for _, key in ipairs { "j", "k" } do
      local motion = function()
        if vim.v.count > 0 or not vim.wo.wrap then return key end
        return "g" .. key
      end
      local desc = ("Down/up by screen line when wrapped (%s)"):format(key)
      maps.n[key] = { motion, expr = true, desc = desc }
      maps.x[key] = { motion, expr = true, desc = desc }
    end
  end,
}
