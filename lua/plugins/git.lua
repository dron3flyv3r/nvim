-- Git: a review view you can revert from, and stashing.
--
-- ── WHAT WAS ALREADY HERE ───────────────────────────────────────────────────
--
-- gitsigns owns the gutter and everything hunk-sized *inside a file you are
-- editing*: `æg`/`øg` to walk hunks, `<Leader>gp` to peek at one, `<Leader>gr`
-- to revert one, `<Leader>gs` to stage one, `<Leader>gl` to blame the line.
-- Those keys are AstroNvim's and they are good; none of them are touched here.
--
-- snacks owns the pickers: `<Leader>gt` status, `<Leader>gb` branches,
-- `<Leader>gc` commits, `<Leader>gC` this file's commits.
--
-- What neither of them has is the thing Rider calls the Changes tool window: a
-- list of every changed file down the left, the diff of the selected one beside
-- it, and revert on a keypress in both. gitsigns can only show you the file you
-- are already in (`:Gitsigns diffthis`), and a picker preview is read-only.
-- That is the gap diffview fills, and it is the reason for the one new plugin.
--
-- ── WHY `<Leader>gd` MOVED ──────────────────────────────────────────────────
--
-- It was gitsigns' `diffthis` -- this buffer against the index, in a split.
-- diffview does that and the other four things you wanted from it, under the
-- same name, so `gd` now opens the review view. `:Gitsigns diffthis` still
-- works if you ever want the narrow version.
--
-- The override has to happen inside gitsigns' `on_attach`, not next to the
-- other mappings: gitsigns sets its keys BUFFER-LOCALLY, and a buffer-local
-- mapping beats a global one every time. Setting `<Leader>gd` globally would
-- work everywhere except in a git file, which is the only place it matters.
--
-- ── REVERTING, AND WHY IT IS NOT `<Leader>gr` UNDERNEATH ────────────────────
--
-- `<Leader>gr` reverts a hunk inside the diff too, so the key means the same
-- thing there as it does in the gutter -- but it is NOT gitsigns' `reset_hunk`
-- in that window, and it cannot be. gitsigns always resets to the INDEX, while
-- the diff view may be showing you `main` or `HEAD~3`. Underneath it is Vim's
-- own `do`/`dp`, which revert to whatever is actually in the other pane; that
-- is the only answer that is right in every case. See `revert_hunk`.
--
-- Neither is the write afterwards a plain `:w`. See `write_quietly`.

---@param msg string
---@param level? integer
local function notify(msg, level) require("astrocore").notify(msg, level or vim.log.levels.WARN, { title = "Git" }) end

--- Write after a revert, without letting the formatter loose on the file.
---
--- `plugins/astrolsp.lua` turns format-on-save on for every filetype, so a
--- bare `:write` here would revert one hunk and reformat the other two hundred
--- lines -- turning "undo this change" into a diff against everything. AstroLSP
--- reads `vim.b.autoformat` at write time (it is what `<Leader>uf` toggles), so
--- switching it off around the write is the supported way to say "save this,
--- don't touch it". `nil` afterwards is not a bug: unset is the default state,
--- and assigning nil restores it.
local function write_quietly()
  local previous = vim.b.autoformat
  vim.b.autoformat = false
  local ok, err = pcall(vim.cmd, "silent write")
  vim.b.autoformat = previous
  if not ok then notify(tostring(err), vim.log.levels.ERROR) end
end

--- Is this buffer the actual file on disk, as opposed to a rendering of some
--- revision of it?
---
--- Not `modifiable` -- MEASURED, and this is the whole reason `revert_hunk` is
--- more than three lines: diffview leaves its `diffview://.../:0:/foo.lua`
--- buffers modifiable with an empty `buftype`, so a naive "am I allowed to edit
--- here" check says yes in the pane showing the OLD version, `do` cheerfully
--- rewrites history-in-a-buffer, and the write that follows aims at a path with
--- a `://` in it. The scheme in the name is what actually distinguishes them --
--- `user/lsp_file_events.lua` sorts fugitive and remote buffers out the same
--- way.
---@param buf integer
---@return boolean
local function is_worktree_buf(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  return vim.bo[buf].buftype == "" and name ~= "" and not name:find("://", 1, true)
end

--- The buffer a revert should land in, and whether the cursor is already in it.
---
--- In a working-tree diff exactly one of the two panes is the file on disk;
--- everything else in the tabpage is a rendering of some revision. A revert
--- always changes that one buffer, whichever side you happen to be reading.
---@return integer? target, boolean from_worktree
local function diff_target()
  local here = vim.api.nvim_get_current_buf()
  if is_worktree_buf(here) then return here, true end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.wo[win].diff and is_worktree_buf(buf) then return buf, false end
  end
end

--- Run one of the `diffget`/`diffput` pair and write the result.
---
--- Which of the two depends on where the cursor is, and they are mirror
--- images: `get` pulls the old text into your file, `put` pushes it there. So
--- the caller says what to revert and this says which direction that is from
--- here -- the key never has to be "wrong window, move over and try again".
---@param worktree_cmd string what to run when the cursor is in your file
---@param other_cmd string what to run when it is in the old version
---@param what string what "nothing happened" should say you were aiming at
local function apply_revert(worktree_cmd, other_cmd, what)
  if not vim.wo.diff then return notify "Not in a diff window" end

  local target, from_worktree = diff_target()
  if not target then return notify "Nothing editable in this diff -- both sides are old revisions" end
  if not vim.bo[target].modifiable or vim.bo[target].readonly then return notify "That file is not modifiable" end

  local before = vim.b[target].changedtick
  local ok, err = pcall(vim.cmd, from_worktree and worktree_cmd or other_cmd)
  if not ok then return notify(tostring(err), vim.log.levels.ERROR) end
  -- Off a change these commands are silent about it. Without this you press
  -- the key, nothing happens, and there is no telling that from a no-op.
  if vim.b[target].changedtick == before then return notify("No " .. what .. " here -- n / N jump to one") end

  vim.api.nvim_buf_call(target, write_quietly)
  vim.cmd.diffupdate()
end

--- Revert the whole change under the cursor. Rider's `»` chevron.
--- `do` and `dp` are Vim's own hunk-sized pair: "diff obtain" and "diff put".
local function revert_hunk() apply_revert("normal! do", "normal! dp", "change under the cursor") end

--- Revert exactly these lines of the change, rather than all of it.
---
--- The case this exists for is a large DELETION you want back a line at a
--- time. That only works from the left pane, and not by accident: lines you
--- deleted do not exist in your file, so there is nothing there to put a range
--- around -- diff mode draws them as filler, which is a picture, not text. In
--- the old-version pane they are real lines with real numbers, and
--- `:{range}diffput` inserts them back one at a time.
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

--- `u`: take back the last revert -- from either pane.
---
--- Plain `u` would half-work. It undoes the buffer you are standing in, and a
--- revert always lands in the worktree one however you triggered it, so from
--- the left pane you would be undoing a rendering of an old commit and your
--- file would keep the change. It also leaves the file on disk holding the
--- reverted text, because `apply_revert` wrote it -- so this re-writes too,
--- and the diff you are looking at stays true.
local function undo_revert()
  local target = diff_target()
  if not target then return notify "Nothing editable in this diff -- both sides are old revisions" end
  vim.api.nvim_buf_call(target, function()
    local before = vim.b.changedtick
    local ok, err = pcall(vim.cmd, "silent undo")
    if not ok then return notify(tostring(err), vim.log.levels.ERROR) end
    if vim.b.changedtick == before then return notify "Nothing left to undo in this file" end
    write_quietly()
  end)
  vim.cmd.diffupdate()
end

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

--- Say which pane is which, in the window bar.
---
--- A two-pane diff is only readable once you know which side is yours, and
--- there is nothing on screen that says so -- both panes hold your file's
--- text and both look editable. diffview can label them (`winbar_info`), but
--- in git's vocabulary: `INDEX - a1b2c3d4:foo.lua`. This says the same thing
--- in yours, coloured like the diff itself: green is the file you are
--- working on, red is the version it is being measured against.
---
--- `diff_buf_win_enter` is diffview's supported hook for this and fires once
--- per pane as an entry opens.
---@param bufnr integer
---@param winid integer
---@param ctx { symbol: string, layout_name: string }
local function label_pane(bufnr, winid, ctx)
  local hl, text
  if is_worktree_buf(bufnr) then
    hl, text = "DiffAdd", "YOURS -- the file on disk. Reverts land here, whichever pane you press them in."
  elseif ctx.symbol == "a" then
    -- The left side of a file-history diff is a commit too, not the index,
    -- so this deliberately does not say "committed".
    hl, text = "DiffDelete", "BEFORE -- what you are comparing against. Lines you deleted still exist here."
  else
    hl, text = "DiffChange", "AFTER -- a past version of the file, not the one you are editing."
  end
  vim.wo[winid].winbar = ("%%#%s# %s "):format(hl, text)
end

--- Make `q` work when the diff has nothing left to show.
---
--- Revert the last change in a review and the view empties: diffview loads a
--- shared scratch buffer, `diffview://null`, into both panes. That buffer
--- never receives the `view` keymaps -- MEASURED, and it is a bug upstream
--- rather than a setting. `File.load_null_buffer` calls `attach_buffer()` with
--- no arguments, and the keymap loop inside it is guarded by
--- `force or new_opt or not cur_state` where `cur_state` is
--- `File.attached[bufnr] or {}`: the fallback makes `not cur_state` false
--- forever, so with no `force` and no `opt` nothing is ever bound.
--- (diffview.nvim 4516612.)
---
--- The result is a blank window where `q` is Vim's start-recording-a-macro
--- again -- it consumes the keypress and does nothing visible, which reads
--- exactly like a freeze. Binding it back is the whole fix; the window bar
--- says what happened, since an empty view otherwise shows you nothing at all.
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

--- Put the cursor on the first (or last) change in the file just opened.
---
--- `]c` from line 1 of a file whose line 1 is already changed jumps PAST it, so
--- stepping into a new file would silently skip its opening change. `diff_hlID`
--- is the check for "is this line part of a change", and answers it directly.
---@param reverse boolean
local function goto_edge_change(reverse)
  vim.cmd("normal! " .. (reverse and "G" or "gg"))
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  if vim.fn.diff_hlID(lnum, 1) == 0 then pcall(vim.cmd, "normal! " .. (reverse and "[c" or "]c")) end
end

--- Next / previous change, rolling over into the next file at the ends.
---
--- Bound to `n` and `N` -- one key, because a review of a real changeset is
--- hundreds of these presses and `æc` is three. Walking the changes IS the
--- next-thing key in a diff, which is what `n` means everywhere else.
---
--- The cost is search-repeat, and only inside this window: `/foo<CR>` still
--- finds the first match, `/<CR>` repeats it forwards and `g?<CR>` backwards
--- (`?` is the cheatsheet in this config -- see `danish-keys.lua`). The
--- mapping is buffer-local and normal-mode only, so `n` is untouched
--- everywhere else and `dn` still works here.
---
--- `]c`/`[c` -- and therefore `æc`/`øc` -- keep doing the same thing.
---
--- Plain `]c` stops at the end of the file and says nothing, which in a review
--- of eleven files means eleven manual `<Tab>`s. This is Rider's F7: one key
--- that walks every change in the changeset in order.
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
      local actions = require "diffview.actions"
      local close = "<Cmd>DiffviewClose<CR>"

      return {
        -- Highlight the changed WORDS inside a changed line, not just the line.
        -- Rider does this and it is most of why its diffs are readable.
        enhanced_diff_hl = true,
        hooks = { diff_buf_win_enter = label_pane },
        file_panel = {
          listing_style = "tree",
          win_config = { position = "left", width = 35 },
        },
        keymaps = {
          -- `disable_defaults` stays off: diffview's own keys (`<Tab>` next
          -- file, `-` stage, `S`/`U` stage-all/unstage-all, `g?` for the full
          -- list) are the ones this view is documented with everywhere.
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
            { "n", "<Leader>gr", revert_hunk, { desc = "Revert this change" } },
            { "x", "<Leader>gr", revert_selection, { desc = "Revert the selected lines" } },
            -- `gl` is gitsigns' blame-this-line everywhere else, and is taken
            -- over here on purpose: in a diff of uncommitted work the left pane
            -- IS the commit you would be blaming against, so blame has nothing
            -- to say, while "just this one line of the block I deleted" is the
            -- thing you actually reach for.
            { "n", "<Leader>gl", revert_line, { desc = "Revert this line only" } },
            -- The whole file, from inside the diff. `X` does this on the file
            -- panel and is diffview's own default there; in the diff itself `X`
            -- is still Vim's delete-a-character, which you may well want in a
            -- pane you can edit. So the capital-is-wider pair from gitsigns
            -- (`gr` hunk / `gR` buffer) carries over instead.
            { "n", "<Leader>gR", actions.restore_entry, { desc = "Revert the whole file" } },
          },
          file_panel = {
            { "n", "q", close, { desc = "Close the diff" } },
          },
          file_history_panel = {
            { "n", "q", close, { desc = "Close the history" } },
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

      -- ── Diff ────────────────────────────────────────────────────────────
      maps.n["<Leader>gd"] = { "<Cmd>DiffviewOpen<CR>", desc = "Diff all changes" }

      -- Against another branch. Plain `DiffviewOpen <ref>` compares your
      -- working tree with that ref as it is now; `<ref>...HEAD` (typed by hand)
      -- is the other useful question -- only what YOU changed since the two
      -- branches parted.
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

      -- ── Stash ───────────────────────────────────────────────────────────
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
