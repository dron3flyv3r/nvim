-- Project execution is owned by Overseer. User-facing selection and control
-- live in the contextual action registry (`<Leader>r`); this spec only keeps
-- the shared task engine and its passive, full-width output surface configured.
---@type LazySpec
return {
  "stevearc/overseer.nvim",
  init = function() require("user.task_pty").setup() end,
  opts = {
    task_list = { direction = "right" },
    output = { use_terminal = true },
    component_aliases = {
      default = {
        "on_exit_set_status",
        "on_complete_notify",
        { "on_complete_dispose", require_view = { "SUCCESS", "FAILURE" } },
        "user_output_pane",
      },
    },
  },
  dependencies = {
    {
      "AstroNvim/astrocore",
      opts = function(_, opts)
        local maps = assert(opts.mappings)
        maps.n["<leader>M"] = false
        for _, key in ipairs { "t", "c", "r", "a", "i" } do
          maps.n["<leader>M" .. key] = false
        end
      end,
    },
  },
}
