-- Points: a handful of places to bounce between while working. `lua/user/points.lua`
-- explains why the jump key is `'` rather than the `` ` `` Vim documents, and
-- `lua/user/points/prompt.lua` why the indicator is a float.
---@type LazySpec
return {
  "AstroNvim/astrocore",
  ---@param opts AstroCoreOpts
  opts = function(_, opts)
    local maps = assert(opts.mappings)

    -- `m` and `'` read their own letter rather than being mapped per letter,
    -- so the prompt can be shown while it waits and `mA`, `''` and `'.` do not
    -- sit out `timeoutlen` before falling through.
    maps.n["m"] = { function() require("user.points.prompt").mark() end, desc = "Set point" }
    maps.n["'"] = { function() require("user.points.prompt").jump() end, desc = "Jump to point" }
    for _, mode in ipairs { "x", "o" } do
      maps[mode] = maps[mode] or {}
      maps[mode]["'"] = {
        function() return require("user.points.prompt").motion() end,
        expr = true,
        desc = "Point as a motion",
      }
    end

    -- `ø'` / `æ'` on a Danish layout, through the existing bracket aliases.
    maps.n["]'"] = { function() require("user.points").walk(1) end, desc = "Next point" }
    maps.n["['"] = { function() require("user.points").walk(-1) end, desc = "Previous point" }

    opts.autocmds = opts.autocmds or {}
    opts.autocmds.user_points = {
      {
        event = "VimEnter",
        desc = "Points last one session: drop the marks shada restored",
        callback = function() require("user.points").clear() end,
      },
    }
  end,
}
