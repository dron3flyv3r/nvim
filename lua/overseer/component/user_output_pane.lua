---@type overseer.ComponentFileDefinition
return {
  desc = "Show the task output in the bottom pane",
  params = {
    focus = {
      desc = "Move the cursor into the output when it opens",
      type = "boolean",
      default = false,
    },
  },
  constructor = function(params)
    ---@type overseer.ComponentSkeleton
    return {
      on_start = function(_, task) require("user.task_output").open(task, { enter = params.focus }) end,
    }
  end,
}
