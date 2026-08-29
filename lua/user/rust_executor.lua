-- Run rustaceanvim's runnables as overseer tasks.
--
-- WHAT RUSTACEANVIM DOES BY DEFAULT: `<Leader>Rr` asks rust-analyzer what is
-- runnable at the cursor -- this binary, this example, this `#[test]` -- and
-- hands the winner to a `rustaceanvim.Executor`. The shipped ones each open
-- their own window: `termopen` splits a scratch terminal and binds `<Esc>` to
-- close it, `toggleterm` wants a plugin this config does not have, `quickfix`
-- throws the output away and keeps only the errors.
--
-- WHY THAT IS THE WRONG SHAPE HERE: every other way of running something in
-- this config goes through overseer and lands in the bottom output pane --
-- `<Leader>rr` for a project's own tasks, `<Leader>Cb` for a CMake build,
-- `<Leader>rf` for a Python module. That pane is not just a window; it is the
-- whole set of verbs that come with it:
--
--     <Leader>rl   re-run the last task           <Leader>ro  look at it
--     <Leader>rk   kill it                        <Leader>ri  type at it
--     <Leader>rq   queue behind the current run   <Leader>rt  what is running
--     æq / øq      step through the errors
--
-- With `termopen`, `<Leader>Rr` would be the one run in this editor that has
-- none of them: a split you close with `<Esc>` and re-open by pressing the key
-- again. So the executor below is a two-line adapter -- take the command
-- rust-analyzer resolved, start it as an overseer task -- and Rust runs join
-- everything else.
--
-- See `plugins/rust-run.lua`, which installs this on all three executor slots.

local M = {}

--- Cargo's error format, for the quickfix list. Also used by the scratch-file
--- template in `overseer/template/user_rust.lua`, which runs rustc directly.
---
--- Copied from overseer's own `cargo` template (`lua/overseer/template/
--- cargo.lua`) -- verbatim except for the last pattern, which is added here and
--- explained where it sits. Copied on purpose: `<Leader>rr` -> `cargo build` and
--- `<Leader>Rr` -> `cargo run --bin foo` are the same compiler saying the same
--- thing, and they should produce the same quickfix entries. Overseer does not
--- export it, hence the copy rather than a `require`.
---
--- Neovim's built-in errorformat cannot stand in the way it can for gcc (see
--- `cpp-cmake.lua`, which deliberately omits this): rustc puts the message on
--- one line (`error[E0382]: borrow of moved value: `x``) and the file:line:col
--- on the *next* one, behind an arrow (`  --> src/main.rs:7:5`). That is a
--- multi-line pattern, and nothing in the default handles it -- without this
--- every error would land in quickfix with no file to jump to.
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
  -- ── The wrapped-header fallback ─────────────────────────────────────────
  --
  -- Task output goes through a terminal, and a terminal hard-wraps at the
  -- window width -- the limit `overseer/template/user_python.lua` documents at
  -- length for tracebacks. For rustc it bites on the FIRST line of an error:
  --
  --     error[E0502]: cannot borrow `v` as mutable because it is also borrowed
  --     as immutable                      <- the pane wrapped it to here
  --      --> src/main.rs:4:5
  --
  -- The `%E` above matches the first row, the orphaned `as immutable` matches
  -- no `%C`, so the entry closes with no location and `æq` has nothing to jump
  -- to -- the whole error becomes unnavigable because the summary was long.
  --
  -- This line catches exactly that case and nothing else. Errorformat tries its
  -- patterns in order and a `%C` only applies while a multi-line entry is open,
  -- so when the header matched normally the `--> ` row is consumed as the
  -- continuation above and never reaches here. It is only when the header
  -- wrapped -- leaving no entry open -- that this matches, giving an entry with
  -- the right file and line and no message. The message is still on screen in
  -- the output pane; what was missing was the jump.
  [[%E %#--> %f:%l:%c]],
}, ",")

--- How much of the command to keep in the task's name.
---
--- rust-analyzer's test runnables are long -- `cargo test --package spined
--- --lib -- store::tests::round_trips --exact --nocapture` -- and the name is
--- what the task list and the output pane's title show. The head of it is the
--- part that identifies the run; the tail is boilerplate repeated on every one.
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
            -- DELIBERATELY OFF, unlike the C++ tasks. rust-analyzer already
            -- publishes exactly these errors as diagnostics -- its `check`
            -- runs the same cargo. Turning this on would put a second copy of
            -- every error in the sign column, and worse, a *stale* copy: the
            -- build's diagnostics do not clear when you fix the line, so they
            -- would sit there contradicting the live ones. This is the same
            -- rule `python-lsp.lua` follows -- one tool per job.
            set_diagnostics = false,
          },
        },
      })
      :start()
  end,
}

return M
