-- A fallback picker for project-specific actions that do not deserve a global
-- mapping. Frequent Unity and Rust actions have dedicated mappings.
---@type LazySpec
return {
  "AstroNvim/astrocore",
  init = function() require("user.context").setup() end,
  ---@param opts AstroCoreOpts
  opts = function(_, opts)
    local maps = assert(opts.mappings)
    local context = require "user.context"
    maps.n["<Leader>r"] = { desc = "Project" }
    maps.n["<Leader>ra"] = { context.pick, desc = "Actions available here" }

    opts.commands = opts.commands or {}
    opts.commands.ContextActions = { context.pick, desc = "Choose an action valid in the current context" }
    opts.commands.ContextStatus = { context.status, desc = "Explain the detected project and action context" }
  end,
}
