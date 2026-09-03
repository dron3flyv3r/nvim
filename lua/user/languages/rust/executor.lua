local M = {}

M.errorformat = table.concat({
  [[%Eerror: %\%%(aborting %\|could not compile%\)%\@!%m]],
  [[%Eerror[E%n]: %m]],
  [[%Inote: %m]],
  [[%Wwarning: %\%%(%.%# warning%\)%\@!%m]],
  [[%C %#--> %f:%l:%c]],
  [[%E  left:%m]],
  [[%C right:%m %f:%l:%c]],
  [[%Z]],
  [[%.%#panicked at \'%m\'\, %f:%l:%c]],
  [[%E %#--> %f:%l:%c]],
}, ",")

local NAME_LIMIT = 60

--- A task name from the command rust-analyzer resolved.
---@param cmd string
---@param args string[]
---@return string
local function task_name(cmd, args)
  local full = table.concat(vim.list_extend({ cmd }, args), " ")
  if #full <= NAME_LIMIT then return full end
  return full:sub(1, NAME_LIMIT - 1) .. "…"
end

--- The executor rustaceanvim calls. Signature is `rustaceanvim.Executor`.
---@type rustaceanvim.Executor
M.executor = {
  ---@param cmd string The binary, normally `cargo`.
  ---@param args string[] Already split -- no shell, no quoting to get wrong.
  ---@param cwd string|nil
  ---@param opts? rustaceanvim.ExecutorOpts `env`, and `bufnr` on the test path.
  execute_command = function(cmd, args, cwd, opts)
    opts = opts or {}
    require("overseer")
      .new_task({
        name = task_name(cmd, args),
        cmd = vim.list_extend({ cmd }, args),
        cwd = cwd,
        -- rust-analyzer sets this for runnables that need it -- a
        -- `[env]` block in `.cargo/config.toml`, or `RUST_BACKTRACE`.
        env = opts.env,
        components = {
          -- `default` is this config's version (see `tasks.lua`): status,
          -- notify, dispose, and the bottom output pane.
          "default",
          {
            "on_output_quickfix",
            errorformat = M.errorformat,
            -- The output pane is already opening for this task. The quickfix
            -- window on top of it would be a second window showing a subset of
            -- the same text -- `<Leader>xq` when the list is what you want.
            open = false,
            open_on_match = false,
            -- Without this every line cargo prints becomes an entry with no
            -- file and no line, and `æq` walks you through "Compiling
            -- serde v1.0.219" on the way to the actual error.
            items_only = true,
            set_diagnostics = false,
          },
        },
      })
      :start()
  end,
}

return M
