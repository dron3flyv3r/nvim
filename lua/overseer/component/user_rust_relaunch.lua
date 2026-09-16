-- The half of the Rust watcher that cannot live on the build task's command
-- line: relaunch the program, but only when the build actually produced a new
-- binary. On a failure this does nothing, which is what leaves the last good
-- process running instead of dropping you to no process at all.
---@type overseer.ComponentFileDefinition
return {
  desc = "Relaunch the Rust watch process after a successful build",
  params = {
    root = {
      desc = "Workspace root whose watcher owns the process",
      type = "string",
    },
  },
  constructor = function(params)
    ---@type overseer.ComponentSkeleton
    return {
      on_complete = function(_, _, status)
        if status ~= require("overseer.constants").STATUS.SUCCESS then return end
        require("user.languages.rust.watch").relaunch(params.root)
      end,
    }
  end,
}
