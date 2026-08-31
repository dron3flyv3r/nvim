--- `git stash`, as two keys and a `:Stash` command.
---
--- Rider's Shelve/Unshelve dialog has a message field and an "include
--- untracked" checkbox, and that is genuinely the whole feature. So this is not
--- a git wrapper -- it is those two inputs, plus the three things that dialog
--- does around them and a terminal does not:
---
---   * it stashes what you can SEE, not what is on disk;
---   * it says "nothing to stash" instead of printing git's exit code;
---   * it reloads the buffers afterwards, because the files just changed
---     underneath them.
---
--- ── STASHING WHAT YOU CAN SEE ───────────────────────────────────────────────
---
--- `git stash` reads the working tree from disk. Neovim's buffers are not the
--- disk -- an unwritten buffer is an edit git cannot see, so it does not get
--- stashed, and then `git stash` reverts the file on disk while your buffer
--- still holds the newer text. Nothing is lost (the buffer is still dirty), but
--- what you get back from the stash is not what you stashed, which is the one
--- outcome a stash must never produce.
---
--- So `flush()` runs first. It reuses `user.autosave`'s sweep, which knows
--- which buffers may be written and which must not be (see that file -- the
--- disk-conflict prompt in particular). If autosave is switched off, or a
--- buffer is one it refuses to touch, the buffer stays dirty and this warns by
--- name rather than stashing a half-truth silently.
---
--- ── WHY `-u` IS A SEPARATE KEY AND `-a` IS NOT ──────────────────────────────
---
---   * plain -- tracked files only. A new file you have not `git add`ed stays
---     put, which is usually what you want: it cannot conflict with anything.
---   * `-u` -- untracked files come along. The case this exists for: you
---     scaffolded three new files and want the branch clean to look at
---     something else. `<Leader>gZ`.
---   * `-a` -- ignored files too. That is `build/`, `.venv/`, `target/`,
---     `node_modules/`. Stashing those is almost always an accident and popping
---     them back is slow, so it is reachable as `:Stash -a` and has no key.
---
--- ── AFTER A POP THAT CONFLICTS ──────────────────────────────────────────────
---
--- `git stash pop` that hits a conflict writes conflict markers into the files
--- AND KEEPS THE STASH. That is deliberate on git's part -- the stash is your
--- way back if the merge goes badly -- but on a picker it reads as "I pressed
--- pop and nothing happened". `restore()` says so explicitly.

local M = {}

local levels = vim.log.levels

---@param msg string
---@param level? integer
local function notify(msg, level) require("astrocore").notify(msg, level or levels.INFO, { title = "Git stash" }) end

--- Run git and wait. Never a shell: every argument here can contain a space (a
--- stash message, a path), and argv has no quoting to get wrong.
---@param args string[]
---@param cwd string
---@return boolean ok, string output
local function git(args, cwd)
  local cmd = { "git" }
  vim.list_extend(cmd, args)
  local res = vim.system(cmd, { cwd = cwd, text = true }):wait()
  return res.code == 0, vim.trim((res.stdout or "") .. (res.stderr or ""))
end

--- The repository the current buffer belongs to, which is not always Neovim's
--- cwd -- `<Leader>ff` opens files from anywhere.
---
--- Matches `.git` as either a directory or a FILE, because in a worktree or a
--- submodule it is a file containing a `gitdir:` pointer.
---@return string?
function M.root()
  local name = vim.api.nvim_buf_get_name(0)
  local from = (name ~= "" and vim.bo.buftype == "") and vim.fs.dirname(name) or vim.fn.getcwd()
  local dot = vim.fs.find(".git", { path = from, upward = true })[1]
  return dot and vim.fs.dirname(dot) or nil
end

--- Write every buffer that can be written, and name the ones that could not.
--- See the header -- this is what makes the stash match the screen.
---@return string[] unsaved paths, relative, that are NOT in what git will see
local function flush()
  require("user.autosave").sweep()

  local unsaved = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified and vim.bo[buf].buftype == "" and name ~= "" then
      unsaved[#unsaved + 1] = vim.fn.fnamemodify(name, ":~:.")
    end
  end
  return unsaved
end

--- Is there anything for a stash of this mode to pick up?
---
--- `--porcelain` is the machine-readable status and it takes the same
--- untracked/ignored switches the stash does, so the question is asked in
--- exactly the terms it will be answered in.
---@param root string
---@param mode "tracked"|"untracked"|"all"
---@return boolean
local function has_changes(root, mode)
  local args = { "status", "--porcelain", mode == "tracked" and "-uno" or "-uall" }
  if mode == "all" then args[#args + 1] = "--ignored" end
  local ok, out = git(args, root)
  return ok and out ~= ""
end

--- The files on disk just changed. `checktime` re-reads any buffer whose file
--- moved (`polish.lua` relies on the same mechanism after a `git checkout`),
--- and gitsigns has to be told, or the signs in the gutter describe the diff
--- from before the stash.
local function reload()
  vim.cmd.checktime()
  local ok, gitsigns = pcall(require, "gitsigns")
  if ok then gitsigns.refresh() end
end

---@class UserStashPushOpts
---@field untracked? boolean include untracked files (`-u`)
---@field all? boolean include ignored files too (`-a`)
---@field message? string the stash message; `nil` asks for one, `""` lets git write its own

--- Stash. `<Leader>gz`, `<Leader>gZ` and `:Stash` all end up here.
---@param opts? UserStashPushOpts
function M.push(opts)
  opts = opts or {}
  local root = M.root()
  if not root then return notify("Not inside a git repository", levels.WARN) end

  local mode = opts.all and "all" or opts.untracked and "untracked" or "tracked"

  local unsaved = flush()
  if #unsaved > 0 then
    notify(
      ("These buffers are unsaved and will NOT be in the stash:\n  %s"):format(table.concat(unsaved, "\n  ")),
      levels.WARN
    )
  end

  if not has_changes(root, mode) then
    -- The tracked-only case is the one worth explaining: there may well be
    -- untracked files sitting right there in the gutter, and "nothing to
    -- stash" would look like a lie.
    return notify(
      mode == "tracked" and "Nothing to stash -- untracked files need <Leader>gZ" or "Nothing to stash",
      levels.WARN
    )
  end

  local function run(message)
    local args = { "stash", "push" }
    if mode == "all" then
      args[#args + 1] = "--all"
    elseif mode == "untracked" then
      args[#args + 1] = "--include-untracked"
    end
    -- An empty message means no `-m` at all, which is how you get git's own
    -- "WIP on main: 53842f1 Added Rust support". `-m ""` would instead give
    -- you a stash with a blank subject, which is worse than either.
    if message ~= "" then vim.list_extend(args, { "-m", message }) end

    local ok, out = git(args, root)
    reload()
    if not ok then return notify(out, levels.ERROR) end
    notify(("Stashed%s: %s"):format(mode == "tracked" and "" or " (+" .. mode .. ")", message ~= "" and message or out))
  end

  if opts.message then return run(opts.message) end

  vim.ui.input({ prompt = "Stash message (empty = let git name it): " }, function(input)
    -- nil is <Esc>; "" is <CR> on an empty prompt, which is a real answer.
    if input == nil then return notify "Stash cancelled" end
    run(vim.trim(input))
  end)
end

--- Apply a stash back onto the working tree.
---@param item table a snacks git_stash picker item (`.stash` is `stash@{N}`)
---@param verb "pop"|"apply"
local function restore(item, verb)
  local ok, out = git({ "stash", verb, item.stash }, item.cwd or M.root())
  reload()
  if ok then return notify(("Stash %s: %s"):format(verb == "pop" and "popped" or "applied", item.msg or item.stash)) end
  -- Per the header: a conflicting pop is not a failed pop. The files have
  -- conflict markers in them and the stash is still in the list.
  notify(("git stash %s hit a problem -- %s is still in the list.\n%s"):format(verb, item.stash, out), levels.ERROR)
end

--- The stash list. `<Leader>gT`.
---
--- snacks already has the finder, the formatter and a preview that shows the
--- stash's full diff; all that is missing is that its only action is `apply`.
--- Enter becomes `pop` (you almost always want the entry gone), with `apply`
--- and `drop` added beside it.
---
--- The letter keys are normal-mode only -- the picker opens in insert mode with
--- the cursor in the filter box, where `a` and `d` have to stay being `a` and
--- `d`. `<C-y>` and `<C-x>` are the same two actions without leaving insert;
--- both are free in snacks' default key table.
function M.list()
  if not M.root() then return notify("Not inside a git repository", levels.WARN) end
  local ok, snacks = pcall(require, "snacks")
  if not ok then return notify("snacks.nvim is not loaded", levels.ERROR) end

  --- Dropping is the one irreversible action here, so it asks. The picker is
  --- closed first and reopened after: `vim.fn.confirm` draws on the command
  --- line, and a blocking prompt underneath a floating picker that is waiting
  --- for input of its own is a fight over the keyboard. Reopening also
  --- re-runs `git stash list`, which matters because dropping renumbers every
  --- entry below the one that went.
  local function drop(picker, item)
    if not item then return end
    picker:close()
    vim.schedule(function()
      local choice = vim.fn.confirm(("Drop %s?\n%s"):format(item.stash, item.msg or ""), "&Drop\n&Cancel", 2, "Warning")
      if choice == 1 then
        local dropped, out = git({ "stash", "drop", item.stash }, item.cwd or M.root())
        notify(dropped and ("Dropped " .. item.stash) or out, dropped and levels.INFO or levels.ERROR)
      end
      M.list()
    end)
  end

  snacks.picker.git_stash {
    confirm = function(picker, item)
      picker:close()
      if item then restore(item, "pop") end
    end,
    actions = {
      stash_apply = function(picker, item)
        picker:close()
        if item then restore(item, "apply") end
      end,
      stash_drop = drop,
    },
    win = {
      input = {
        keys = {
          ["a"] = { "stash_apply", mode = { "n" }, desc = "apply (keep in list)" },
          ["<C-y>"] = { "stash_apply", mode = { "i", "n" }, desc = "apply (keep in list)" },
          ["d"] = { "stash_drop", mode = { "n" }, desc = "drop" },
          ["<C-x>"] = { "stash_drop", mode = { "i", "n" }, desc = "drop" },
        },
      },
    },
  }
end

--- `:Stash [-u|-a] [message]`.
---
--- The flags are read off the front so that `:Stash -u wip on the parser` is
--- one obvious line, and a message with no flags needs no quoting. No message
--- means the same prompt the keys give you -- `:Stash` and `<Leader>gz` are the
--- same command by two routes.
---@param args table the `nvim_create_user_command` argument table
function M.command(args)
  local words, i = args.fargs, 1
  local opts = {}

  while true do
    local word = words[i]
    if word == "-u" or word == "--include-untracked" then
      opts.untracked = true
    elseif word == "-a" or word == "--all" then
      opts.all = true
    else
      break
    end
    i = i + 1
  end

  local message = table.concat(vim.list_slice(words, i), " ")
  if message ~= "" then opts.message = message end
  M.push(opts)
end

return M
