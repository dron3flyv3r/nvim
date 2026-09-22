---@type overseer.ComponentFileDefinition
return {
  desc = "Write modified buffers before the task starts",
  constructor = function()
    ---@type overseer.ComponentSkeleton
    return {
      on_pre_start = function() require("user.autosave").sweep() end,
    }
  end,
}
