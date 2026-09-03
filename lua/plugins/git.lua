---@param msg string
---@param level? integer
local function notify(msg, level) require("astrocore").notify(msg, level or vim.log.levels.WARN, { title = "Git" }) end

---@param buf integer
---@return boolean
local function is_worktree_buf(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  return vim.bo[buf].buftype == "" and name ~= "" and not name:find("://", 1, true)
end

---@return integer? target, boolean from_worktree
local function diff_target()
  local here = vim.api.nvim_get_current_buf()
  if is_worktree_buf(here) then return here, true end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.wo[win].diff and is_worktree_buf(buf) then return buf, false end
  end
end

---@param worktree_cmd string what to run when the cursor is in your file
---@param other_cmd string what to run when it is in the old version
---@param what string what "nothing happened" should say you were aiming at
local function apply_revert(worktree_cmd, other_cmd, what)
  if not vim.wo.diff then return notify "Not in a diff window" end

  local target, from_worktree = diff_target()
  if not target then return notify "Nothing editable in this diff -- both sides are old revisions" end
  if not vim.bo[target].modifiable or vim.bo[target].readonly then return notify "That file is not modifiable" end
  if not require("user.diff_review").track(target) then return notify "This is not a working-tree review" end

  local before = vim.b[target].changedtick
  local ok, err = pcall(vim.cmd, from_worktree and worktree_cmd or other_cmd)
  if not ok then return notify(tostring(err), vim.log.levels.ERROR) end
  -- Off a change these commands are silent about it. Without this you press
  -- the key, nothing happens, and there is no telling that from a no-op.
  if vim.b[target].changedtick == before then return notify("No " .. what .. " here -- n / N jump to one") end

  vim.cmd.diffupdate()
end

--- Revert the whole change under the cursor. Rider's `»` chevron.
--- `do` and `dp` are Vim's own hunk-sized pair: "diff obtain" and "diff put".
local function revert_hunk() apply_revert("normal! do", "normal! dp", "change under the cursor") end

---@param first integer
---@param last integer
local function revert_lines(first, last)
  local range = ("%d,%d"):format(first, last)
  apply_revert(range .. "diffget", range .. "diffput", "change in those lines")
end

--- `<Leader>gl`: the line the cursor is on, and nothing else.
local function revert_line()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  revert_lines(lnum, lnum)
end

local function undo_revert()
  local target = diff_target()
  if not target then return notify "Nothing editable in this diff -- both sides are old revisions" end
  local review = require "user.diff_review"
  if not review.track(target) then return notify "This is not a working-tree review" end
  if not review.changed(target) then return notify "Nothing from this review to undo in this file" end
  vim.api.nvim_buf_call(target, function()
    local before = vim.b.changedtick
    local ok, err = pcall(vim.cmd, "silent undo")
    if not ok then return notify(tostring(err), vim.log.levels.ERROR) end
    if vim.b.changedtick == before then return notify "Nothing left to undo in this file" end
  end)
  vim.cmd.diffupdate()
end

---Rider's whole-file rollback, but still only in memory until the exit prompt.
local function revert_file() apply_revert("%diffget", "%diffput", "change in this file") end

--- `<Leader>gr` from visual mode: the lines you selected, and no others.
--- `'<`/`'>` are not set until the selection ends, so the bounds are read
--- while it is still live -- `v` is the anchor, `.` is the cursor.
local function revert_selection()
  local first, last = vim.fn.line "v", vim.fn.line "."
  if first > last then
    first, last = last, first
  end
  vim.cmd "normal! \27"
  revert_lines(first, last)
end

---@param bufnr integer
---@param winid integer
---@param ctx { symbol: string, layout_name: string }
local function label_pane(bufnr, winid, ctx)
  local hl, text
  if is_worktree_buf(bufnr) then
    hl, text = "DiffAdd", "YOURS -- safe review buffer. Nothing is written until q -> Save."
  elseif ctx.symbol == "a" then
    -- The left side of a file-history diff is a commit too, not the index,
    -- so this deliberately does not say "committed".
    hl, text = "DiffDelete", "BEFORE -- what you are comparing against. Lines you deleted still exist here."
  else
    hl, text = "DiffChange", "AFTER -- a past version of the file, not the one you are editing."
  end
  vim.wo[winid].winbar = ("%%#%s# %s "):format(hl, text)
end

---@param buf integer
local function dress_empty_view(buf)
  vim.keymap.set("n", "q", "<Cmd>DiffviewClose<CR>", {
    buffer = buf,
    nowait = true,
    desc = "Close the diff",
  })
  -- `BufWinEnter` does not say which window, and both panes show this buffer.
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == buf then
      vim.wo[win].winbar = "%#Comment# Nothing left to review -- press q to close "
    end
  end
end

---@param reverse boolean
local function goto_edge_change(reverse)
  vim.cmd("normal! " .. (reverse and "G" or "gg"))
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  if vim.fn.diff_hlID(lnum, 1) == 0 then pcall(vim.cmd, "normal! " .. (reverse and "[c" or "]c")) end
end

---@param reverse boolean
---@return function
local function nav_change(reverse)
  return function()
    local before = vim.api.nvim_win_get_cursor(0)[1]
    local ok = pcall(vim.cmd, "normal! " .. (reverse and "[c" or "]c"))
    if ok and vim.api.nvim_win_get_cursor(0)[1] ~= before then return end

    local actions = require "diffview.actions"
    if reverse then
      actions.select_prev_entry()
    else
      actions.select_next_entry()
    end
    -- Loading an entry is asynchronous -- the buffers, the diff and the window
    -- layout are not in place on the next tick. This waits for the window to
    -- actually be showing a diff before jumping, rather than guessing a delay.
    local tries = 0
    local timer = assert((vim.uv or vim.loop).new_timer())
    timer:start(
      20,
      20,
      vim.schedule_wrap(function()
        tries = tries + 1
        if vim.wo.diff or tries > 25 then
          timer:stop()
          timer:close()
          if vim.wo.diff then goto_edge_change(reverse) end
        end
      end)
    )
  end
end

---@type LazySpec
return {
  {
    "sindrets/diffview.nvim",
    cmd = {
      "DiffviewOpen",
      "DiffviewClose",
      "DiffviewToggleFiles",
      "DiffviewFocusFiles",
      "DiffviewRefresh",
      "DiffviewFileHistory",
    },
    opts = function()
      local review = require "user.diff_review"
      review.install_close_command()
      local close = review.close
      local blocked = review.block_index_change

      return {
        -- Highlight the changed WORDS inside a changed line, not just the line.
        -- Rider does this and it is most of why its diffs are readable.
        enhanced_diff_hl = true,
        hooks = {
          diff_buf_win_enter = function(bufnr, winid, ctx)
            label_pane(bufnr, winid, ctx)
            review.track(bufnr)
          end,
          view_closed = review.closed,
        },
        file_panel = {
          listing_style = "tree",
          win_config = { position = "left", width = 35 },
        },
        keymaps = {
          -- Defaults stay on for motions, folds and g? help. Mutating Git's
          -- index is overridden below because it cannot participate in the
          -- in-memory review transaction.
          view = {
            { "n", "q", close, { desc = "Close the diff" } },

            -- Walking the changeset -- see `nav_change` for why one key.
            { "n", "n", nav_change(false), { desc = "Next change (into the next file)" } },
            { "n", "N", nav_change(true), { desc = "Previous change (into the previous file)" } },
            { "n", "]c", nav_change(false), { desc = "Next change (into the next file)" } },
            { "n", "[c", nav_change(true), { desc = "Previous change (into the previous file)" } },

            -- Reverting, at three sizes, and the way back. `u` is Vim's own
            -- undo doing what you already expect it to -- see `undo_revert`
            -- for the two things it has to do that plain `u` does not.
            { "n", "u", undo_revert, { desc = "Undo the last revert" } },
            { "n", "r", revert_hunk, { desc = "Revert this change (pending)" } },
            { "n", "R", revert_file, { desc = "Revert this file (pending)" } },
            { "n", "<Leader>gr", revert_hunk, { desc = "Revert this change" } },
            { "x", "<Leader>gr", revert_selection, { desc = "Revert the selected lines" } },
            { "n", "<Leader>gl", revert_line, { desc = "Revert this line only" } },
            { "n", "<Leader>gR", revert_file, { desc = "Revert the whole file (pending)" } },
          },
          file_panel = {
            { "n", "q", close, { desc = "Close the diff" } },
            { "n", "-", blocked, { desc = "Staging disabled during safe review" } },
            { "n", "s", blocked, { desc = "Staging disabled during safe review" } },
            { "n", "S", blocked, { desc = "Staging disabled during safe review" } },
            { "n", "U", blocked, { desc = "Staging disabled during safe review" } },
            { "n", "X", review.block_restore, { desc = "Use R in the diff for a pending whole-file revert" } },
          },
          file_history_panel = {
            { "n", "q", close, { desc = "Close the history" } },
            { "n", "X", review.block_history_restore, { desc = "Restoring history is disabled during safe review" } },
          },
        },
      }
    end,
  },

  -- The keys. Everything reachable without already being in a diff.
  {
    "AstroNvim/astrocore",
    ---@param opts AstroCoreOpts
    opts = function(_, opts)
      -- Guaranteed by `astrocore.lua`, which sets `mappings` in its static opts;
      -- `assert` says so to the type checker instead of nil-checking every line.
      local maps = assert(opts.mappings)
      local stash = function(fn, ...)
        local args = { ... }
        return function() require("user.git_stash")[fn](unpack(args)) end
      end

      maps.n["<Leader>gd"] = { "<Cmd>DiffviewOpen<CR>", desc = "Diff all changes" }

      maps.n["<Leader>gD"] = {
        function()
          require("snacks").picker.git_branches {
            confirm = function(picker, item)
              picker:close()
              local ref = item and (item.branch or item.commit)
              if not ref then return notify "No branch selected" end
              vim.cmd("DiffviewOpen " .. ref)
            end,
          }
        end,
        desc = "Diff against a branch",
      }

      -- File history. The panel lists the commits; picking one diffs it against
      -- its parent, so it is the same two-pane view walking backwards in time.
      maps.n["<Leader>gh"] = {
        function()
          local file = vim.api.nvim_buf_get_name(0)
          if file == "" or vim.bo.buftype ~= "" then
            return notify "No file in this window -- <Leader>gH for the whole repository"
          end
          vim.cmd("DiffviewFileHistory " .. vim.fn.fnameescape(file))
        end,
        desc = "History of this file",
      }
      maps.n["<Leader>gH"] = { "<Cmd>DiffviewFileHistory<CR>", desc = "History of the repository" }

      -- Lower/upper is scope, the same way gitsigns' `gr`/`gR` and `gs`/`gS`
      -- already read in this config: the capital takes more with it.
      maps.n["<Leader>gz"] = { stash "push", desc = "Stash changes" }
      maps.n["<Leader>gZ"] = { stash("push", { untracked = true }), desc = "Stash + untracked files" }
      -- Was snacks' stash picker, whose only action is `apply`. Same picker,
      -- with pop and drop added -- see `user/git_stash.lua`.
      maps.n["<Leader>gT"] = { stash "list", desc = "Stash list (pop/apply/drop)" }

      -- The emptied-out diff view, per `dress_empty_view`. An autocmd rather
      -- than a `view` keymap because the buffer it has to reach is the one
      -- diffview does not hand its keymaps to.
      opts.autocmds = opts.autocmds or {}
      opts.autocmds.diffview_empty_view = {
        {
          event = "BufWinEnter",
          pattern = "diffview://null",
          desc = "Let `q` close a diff view with nothing left in it",
          callback = function(args) dress_empty_view(args.buf) end,
        },
      }

      opts.commands = opts.commands or {}
      opts.commands.Stash = {
        function(args) require("user.git_stash").command(args) end,
        desc = "Stash changes: :Stash [-u|-a] [message]",
        nargs = "*",
      }
    end,
  },

  -- `<Leader>gd` inside a git file, per the header: gitsigns binds it
  -- buffer-locally, so the global mapping above never gets a chance there.
  {
    "lewis6991/gitsigns.nvim",
    opts = function(_, opts)
      local astronvim_on_attach = opts.on_attach
      opts.on_attach = function(bufnr)
        if astronvim_on_attach then astronvim_on_attach(bufnr) end
        require("astrocore").set_mappings({
          n = {
            ["<Leader>gd"] = { "<Cmd>DiffviewOpen<CR>", desc = "Diff all changes" },
          },
        }, { buffer = bufnr })
      end
      return opts
    end,
  },
}
