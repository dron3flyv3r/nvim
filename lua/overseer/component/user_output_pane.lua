-- Show a task's output in the bottom strip when it starts.
--
-- This replaces overseer's own `open_output` in the `default` alias -- see
-- `lua/plugins/tasks.lua`. Same job, different window: `open_output` can only
-- put the output in the dock, sharing the bottom strip with the task list, or
-- in a `:split` wherever the cursor happens to be. `user.task_output` keeps one
-- full-width pane at the bottom instead; that file explains why.
--
-- WHY THIS FILE LIVES AT `lua/overseer/component/`: overseer globs
-- `lua/overseer/component/*.lua` across the whole runtimepath and registers
-- each one under its basename, so this is usable as `"user_output_pane"` with
-- no registration call -- the same discovery trick as `lua/overseer/template/`.
-- Note the glob is one level deep, so unlike templates this cannot be nested in
-- a subdirectory.

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
