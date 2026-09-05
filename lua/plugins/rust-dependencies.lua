---@type LazySpec
return {
  "AstroNvim/astrocore",
  opts = function(_, opts)
    local dependencies = require "user.languages.rust.dependencies"
    opts.commands = opts.commands or {}
    opts.commands.RustDependencySearch = {
      function() dependencies.search() end,
      desc = "Search crates.io and add a dependency",
    }
    opts.commands.RustDependencyFeatures = {
      function() dependencies.features() end,
      desc = "Browse features for Cargo dependencies",
    }
  end,
}
