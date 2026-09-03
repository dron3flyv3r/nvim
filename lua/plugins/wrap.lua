---@type LazySpec
return {
  "AstroNvim/astrocore",
  ---@param opts AstroCoreOpts
  opts = function(_, opts)
    -- Guaranteed by `astrocore.lua`, which sets `mappings` in its static opts;
    -- `assert` says so to the type checker instead of nil-checking every line.
    local maps = assert(opts.mappings)

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
