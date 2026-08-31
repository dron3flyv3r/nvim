-- One project-aware development vocabulary. Editing itself stays native:
-- this prefix is only for actions whose meaning depends on a language,
-- project, external editor, kernel, build system, or debugger.
---@type LazySpec
return {
  "AstroNvim/astrocore",
  init = function() require("user.context").setup() end,
  ---@param opts AstroCoreOpts
  opts = function(_, opts)
    local maps = assert(opts.mappings)
    local context = require "user.context"
    maps.n["<Leader>r"] = { desc = "󰑮 Context" }
    maps.n["<Leader>ra"] = { context.pick, desc = "All contextual actions" }
    maps.n["<Leader>rr"] = { function() context.run_verb "run" end, desc = "Run current context" }
    maps.n["<Leader>rl"] = { context.repeat_last, desc = "Repeat last contextual run" }
    maps.n["<Leader>rt"] = { function() context.run_verb "test" end, desc = "Test current context" }
    maps.n["<Leader>rd"] = { function() context.run_verb "debug" end, desc = "Debug current context" }
    maps.n["<Leader>rb"] = { function() context.run_verb "build" end, desc = "Build current context" }
    maps.n["<Leader>ro"] = { function() context.run_verb "output" end, desc = "Show current output" }
    maps.n["<Leader>rk"] = { function() context.run_verb "stop" end, desc = "Stop current execution" }

    opts.commands = opts.commands or {}
    opts.commands.ContextActions = { context.pick, desc = "Choose an action valid in the current context" }
    opts.commands.ContextStatus = { context.status, desc = "Explain the detected project and action context" }
  end,
}
