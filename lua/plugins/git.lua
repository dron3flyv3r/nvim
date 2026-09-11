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
  -- A file that exists on only one side is shown in a single pane, so there is
  -- no second version for Vim's diff commands to reach for.
  local lone = require("user.diff_hud").lone_kind()
  if lone == "new" then return notify "This file is new -- there is nothing to revert to. Delete the file instead" end
  if lone == "gone" then return notify "This file is deleted -- restore it with git, not from the review" end
  if not vim.wo.diff then return notify "Not in a diff window" end

  local target, from_worktree = diff_target()
  if not target then return notify "Nothing editable in this diff -- both sides are old revisions" end
  if not vim.bo[target].modifiable then return notify "That file is not modifiable" end
  -- Not `readonly`: the review sets that itself to hold the file back from
  -- disk, so only the value it found there says anything about the file.
  local review = require "user.diff_review"
  if not review.track(target) then return notify "This is not a working-tree review" end
  if not review.writable(target) then return notify "That file is read-only on disk" end

  local before = vim.b[target].changedtick
  -- `silent` because the review holds the file with `readonly`, and Neovim's
  -- W10 warning about that arrives dressed as an error from inside `vim.cmd`.
  local ok, err = pcall(vim.cmd, "silent " .. (from_worktree and worktree_cmd or other_cmd))
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

--- The inverse pair, in `user.diff_revert` because working out which hunks to
--- roll back needs a diff of its own rather than Vim's ranged `diffget`.
local function keep_selection() require("user.diff_revert").keep_selection() end
local function unformat() require("user.diff_revert").unformat() end

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

--- Diffview opens with the cursor in the file panel, where none of the review
--- keys are bound -- `n` there used to fall through to Vim's own search and
--- report `E35` or jump to an old match. Panel keys act on the diff instead.
local function focus_diff()
  local ok, lib = pcall(require, "diffview.lib")
  if not ok then return end
  local found, view = pcall(lib.get_current_view)
  local layout = found and view and view.cur_layout or nil
  local main = layout and layout.get_main_win and layout:get_main_win()
  local winid = main and main.id
  if winid and vim.api.nvim_win_is_valid(winid) then vim.api.nvim_set_current_win(winid) end
end

--- The three panes of a merge, and the conflict the RESULT pane's cursor is in.
--- Every conflict action reads that cursor, whichever pane or panel has focus,
--- because the region bounds are lines in the file being written.
---@return table? view, integer? bufnr, integer? winid
local function merge_target()
  local ok, lib = pcall(require, "diffview.lib")
  local found, view = pcall(function() return ok and lib.get_current_view() or nil end)
  local layout = found and view and view.cur_layout or nil
  local main = layout and layout.get_main_win and layout:get_main_win()
  local bufnr = main and main.file and main.file.bufnr
  if not (view and main and main:is_valid() and bufnr and vim.api.nvim_buf_is_valid(bufnr)) then return end
  return view, bufnr, main.id
end

---@param bufnr integer
---@param winid integer
---@return table? the conflict region under the cursor
local function conflict_under(bufnr, winid)
  local parse = require("diffview.vcs.utils").parse_conflicts
  local ok, _, current = pcall(parse, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), winid)
  return ok and current or nil
end

---@param region table
---@param field "ours"|"base"|"theirs"
---@return integer
local function side_length(region, field)
  local side = region[field]
  return side and side.content and #side.content or 0
end

---@type table<string, DiffHudTook>
local TOOK = { ours = "ours", theirs = "theirs", all = "both", none = "dropped" }

---@param target "ours"|"theirs"|"all"|"none"
---@param whole? boolean the whole file rather than the conflict under the cursor
---@return function
local function take_side(target, whole)
  return function()
    local actions = require "diffview.actions"
    -- The whole file is one decision and the counter reports it; the panel
    -- variant also has to open the file it is pointed at, which this does.
    if whole then return actions.conflict_choose_all(target)() end

    local _, bufnr, winid = merge_target()
    if not bufnr then return notify "Not in a merge" end
    local region = conflict_under(bufnr, winid)
    if not region then return notify "No conflict under the cursor -- n and N jump to one" end

    local produced = 0
    if target == "ours" or target == "all" then produced = produced + side_length(region, "ours") end
    if target == "all" then produced = produced + side_length(region, "base") end
    if target == "theirs" or target == "all" then produced = produced + side_length(region, "theirs") end

    actions.conflict_choose(target)()
    require("user.diff_hud").mark(bufnr, region.first, produced, TOOK[target])
  end
end

---The marker lines of a region, by line number rather than by looking like a
---marker: a row of equals signs is a heading in Markdown and a separator only
---between the sides of a conflict.
---@param region table
---@return table<integer, boolean>
local function marker_lines(region)
  local lines = {}
  for _, side in ipairs { "ours", "base", "theirs" } do
    local at = region[side] and region[side].first
    if at then lines[at] = true end
  end
  lines[region.last] = true
  return lines
end

--- Part of a side rather than all of it: the lines are copied into the
--- resolution above the markers and the region is left standing, so takes add
--- up -- two lines from OURS, then one from THEIRS -- until `X` drops the rest.
--- The lines are taken as text, which is why this works from either side pane
--- without mapping its line numbers onto the file being written.
---@param visual boolean
---@return function
local function take_lines(visual)
  return function()
    local first, last = vim.fn.line ".", vim.fn.line "."
    if visual then
      -- Read while the selection is still live: `'<` and `'>` are only set
      -- once it ends. `v` is the anchor and `.` is the cursor.
      first, last = vim.fn.line "v", vim.fn.line "."
      if first > last then
        first, last = last, first
      end
      vim.cmd "normal! \27"
    end

    local _, bufnr, winid = merge_target()
    if not bufnr then return notify "Not in a merge" end
    local region = conflict_under(bufnr, winid)
    if not region then return notify "No conflict under the cursor -- n and N jump to one" end

    -- Only the file being written has markers in it; the side panes are the
    -- clean versions from the index, so everything selected there is content.
    local source = vim.api.nvim_get_current_buf()
    local skip = source == bufnr and marker_lines(region) or {}
    local taken = {}
    for offset, line in ipairs(vim.api.nvim_buf_get_lines(source, first - 1, last, false)) do
      if not skip[first + offset - 1] then taken[#taken + 1] = line end
    end
    if #taken == 0 then return notify "Nothing there but conflict markers" end

    vim.api.nvim_buf_set_lines(bufnr, region.first - 1, region.first - 1, false, taken)
    require("user.diff_hud").mark(bufnr, region.first, #taken, "lines")
    -- Back onto the region's own first line, so the next take and the `X` that
    -- ends it still act on this conflict.
    pcall(vim.api.nvim_win_set_cursor, winid, { region.first + #taken, 0 })
    vim.cmd.diffupdate()
    notify(
      ("Took %d line%s -- X drops the rest of this conflict"):format(#taken, #taken == 1 and "" or "s"),
      vim.log.levels.INFO
    )
  end
end

--- What you already decided, which a resolved region no longer shows: the
--- markers are gone and the lines look like any others.
---@param reverse boolean
---@return function
local function nav_resolution(reverse)
  return function()
    local _, bufnr, winid = merge_target()
    if not bufnr then return notify "Not in a merge" end
    local list = require("user.diff_hud").resolutions(bufnr)
    if #list == 0 then return notify "Nothing resolved in this file yet" end

    local lnum = vim.api.nvim_win_get_cursor(winid)[1]
    local at
    for index, mark in ipairs(list) do
      if reverse then
        if mark.lnum < lnum then at = index end
      elseif mark.lnum > lnum and not at then
        at = index
      end
    end
    -- Wrapping, and saying so: a file has few resolutions and stopping at the
    -- last one just means pressing the other key to get back.
    local wrapped = at == nil
    at = at or (reverse and #list or 1)

    vim.api.nvim_set_current_win(winid)
    vim.api.nvim_win_set_cursor(winid, { math.min(list[at].lnum, vim.api.nvim_buf_line_count(bufnr)), 0 })
    notify(
      ("Resolution %d/%d -- %s%s"):format(at, #list, list[at].took, wrapped and " (wrapped)" or ""),
      vim.log.levels.INFO
    )
  end
end

--- `<Tab>` during a merge: the next file that still has conflicts in it, and
--- only then the next file in the changeset.
local function next_conflicted()
  if require("user.diff_hud").next_conflict_file() then return end
  require("diffview.actions").select_next_entry()
end

---@param reverse boolean
---@return function
local function nav_conflict(reverse)
  return function()
    local actions = require "diffview.actions"
    if reverse then
      actions.prev_conflict()
    else
      actions.next_conflict()
    end
  end
end

--- `do` and `dp` have to be told which buffer when three of them are in diff
--- mode, so the revert keys cannot mean anything during a merge.
---@param whole boolean
---@return function
local function merge_hint(whole)
  return function()
    notify(
      whole and "This is a merge -- gH takes ours for the whole file, gL takes theirs, gB takes both"
        or "This is a merge -- H takes ours, L takes theirs, B takes both, X drops both"
    )
  end
end

--- The ancestor of a conflicted file, read-only, for when the conflict markers
--- do not carry it. Not a resolution: something to read and copy from.
---@param view table
---@param entry table
local function show_ancestor(view, entry)
  local out, code = view.adapter:exec_sync({ "show", ":1:" .. entry.path }, view.adapter.ctx.toplevel)
  if type(out) ~= "table" or code ~= 0 then return notify "This conflict has no common ancestor to show" end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, out)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = vim.filetype.match { filename = entry.path } or ""
  local width = math.min(110, math.max(60, vim.o.columns - 10))
  local height = math.min(#out + 1, math.floor(vim.o.lines * 0.7))
  -- A float rather than a split: a new window inside the layout is a window
  -- Diffview will try to make part of the diff.
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = (" BASE -- %s "):format(entry.path),
    title_pos = "center",
  })
  vim.wo[win].wrap = false
  vim.keymap.set("n", "q", "<Cmd>close<CR>", { buffer = buf, nowait = true, desc = "Close the ancestor" })
end

--- BASE is what both sides started from. Git's default conflict style leaves it
--- out of the markers, so it is only takeable when the repository asked for
--- `diff3`; otherwise the ancestor is shown instead of guessed at.
local function take_base()
  local view = require("diffview.lib").get_current_view()
  local layout = view and view.cur_layout
  local main = layout and layout.get_main_win and layout:get_main_win()
  local entry = view and view.cur_entry
  local bufnr = main and main.file and main.file.bufnr
  if not (entry and bufnr and vim.api.nvim_buf_is_valid(bufnr)) then return notify "Not in a merge" end

  local parse = require("diffview.vcs.utils").parse_conflicts
  local ok, _, current = pcall(parse, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), main.id)
  if not (ok and current) then return notify "No conflict under the cursor -- n and N jump to one" end

  local base = current.base and current.base.content
  if base and #base > 0 then
    vim.api.nvim_buf_set_lines(bufnr, current.first - 1, current.last, false, base)
    require("user.diff_hud").mark(bufnr, current.first, #base, "base")
    return vim.cmd.diffupdate()
  end
  show_ancestor(view, entry)
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
    if vim.api.nvim_win_get_buf(win) == buf then require("user.diff_hud").dress_empty(win) end
  end
end

---@param reverse boolean
local function goto_edge_change(reverse)
  vim.cmd("normal! " .. (reverse and "G" or "gg"))
  -- A file shown in a single pane is entirely new or entirely gone: its edge
  -- is the edge of the file, and `diff_hlID` has nothing to say about it.
  if not vim.wo.diff then return end
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
    -- actually be showing the file before jumping, rather than guessing a delay.
    local tries = 0
    local finished = false
    local timer = assert((vim.uv or vim.loop).new_timer())
    timer:start(
      20,
      20,
      vim.schedule_wrap(function()
        -- Stopping the timer does not cancel callbacks already scheduled while
        -- Diffview was rebuilding the panes. Only the first may close or jump.
        if finished then return end
        tries = tries + 1
        local ready = vim.wo.diff or require("user.diff_hud").lone_kind() ~= nil
        if ready or tries > 25 then
          finished = true
          timer:stop()
          timer:close()
          if ready then goto_edge_change(reverse) end
        end
      end)
    )
  end
end

--- `n` from the file panel: into the diff first, then whatever "next" means
--- there -- the next conflict during a merge, the next change otherwise.
---@param reverse boolean
---@return function
local function panel_nav(reverse)
  return function()
    focus_diff()
    local kind = require("user.diff_hud").current_kind()
    if kind == "ours" or kind == "result" or kind == "theirs" then return nav_conflict(reverse)() end
    nav_change(reverse)()
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
      local hud = require "user.diff_hud"
      review.install_close_command()
      local close = review.close
      local blocked = review.block_index_change

      -- Diffview's own gf opens the file and leaves the review standing over
      -- the hold on that buffer -- see `user.diff_goto`. Its three keys are
      -- taken over rather than left beside new ones so the version that walks
      -- through the transaction cannot be reached by accident.
      ---@param how "edit"|"split"|"tab"
      ---@return function
      local function leave(how)
        return function() require("user.diff_goto").leave(how) end
      end

      -- Attached only in the three- and four-pane merge layouts, and they win
      -- over the `view` maps below, which is what lets `n` mean conflicts here
      -- and changes everywhere else.
      local merge = {
        { "n", "H", take_side "ours", { desc = "Take OURS, the left pane" } },
        { "n", "L", take_side "theirs", { desc = "Take THEIRS, the right pane" } },
        { "n", "B", take_side "all", { desc = "Take both sides, ours first" } },
        { "n", "X", take_side "none", { desc = "Drop both sides" } },
        { "n", "gH", take_side("ours", true), { desc = "Take OURS for the whole file" } },
        { "n", "gL", take_side("theirs", true), { desc = "Take THEIRS for the whole file" } },
        { "n", "gB", take_side("all", true), { desc = "Take both sides for the whole file" } },
        { "n", "<Leader>cb", take_base, { desc = "Take or show BASE, the common ancestor" } },

        -- Line by line: the same key in both modes, so one line is one press
        -- and several lines are a selection.
        { "n", "<CR>", take_lines(false), { desc = "Take this line into the resolution" } },
        { "x", "<CR>", take_lines(true), { desc = "Take the selected lines into the resolution" } },

        { "n", "]r", nav_resolution(false), { desc = "Next resolution, to check it" } },
        { "n", "[r", nav_resolution(true), { desc = "Previous resolution, to check it" } },
        { "n", "<Tab>", next_conflicted, { desc = "Next file with conflicts left in it" } },

        { "n", "n", nav_conflict(false), { desc = "Next conflict" } },
        { "n", "N", nav_conflict(true), { desc = "Previous conflict" } },
        { "n", "]c", nav_conflict(false), { desc = "Next conflict" } },
        { "n", "[c", nav_conflict(true), { desc = "Previous conflict" } },

        { "n", "r", merge_hint(false), { desc = "Reverting is H or L in a merge" } },
        { "n", "R", merge_hint(true), { desc = "Reverting is gH or gL in a merge" } },
        { "n", "<Leader>gr", merge_hint(false), { desc = "Reverting is H or L in a merge" } },
        { "n", "<Leader>gl", merge_hint(false), { desc = "Reverting is H or L in a merge" } },
        { "n", "<Leader>gR", merge_hint(true), { desc = "Reverting is gH or gL in a merge" } },
        { "x", "<Leader>gr", merge_hint(false), { desc = "Reverting is H or L in a merge" } },
        { "x", "<Leader>gk", merge_hint(false), { desc = "Keeping lines is <CR> in a merge" } },
        { "n", "<Leader>gw", merge_hint(false), { desc = "There is no formatting to undo in a merge" } },
      }

      return {
        -- Highlight the changed WORDS inside a changed line, not just the line.
        -- Rider does this and it is most of why its diffs are readable.
        enhanced_diff_hl = true,
        hooks = {
          diff_buf_win_enter = function(bufnr, winid, ctx)
            hud.dress(bufnr, winid, ctx)
            review.track(bufnr)
            require("user.diff_keys").show(hud.current_kind())
          end,
          view_closed = function(view)
            hud.closed()
            review.closed(view)
            require("user.diff_keys").hide()
          end,
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
            {
              "n",
              "?",
              function() require("user.diff_keys").toggle() end,
              { desc = "Show or hide the key legend" },
            },

            -- Out of the review and into the file, settling the transaction on
            -- the way. Bound in `view` so the merge layouts inherit them too.
            { "n", "gf", leave "edit", { desc = "Leave the review and open this file here" } },
            { "n", "<C-w><C-f>", leave "split", { desc = "Leave the review and open this file in a split" } },
            { "n", "<C-w>gf", leave "tab", { desc = "Leave the review and open this file in a new tab" } },

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

            -- The other way round, for when a formatter has rewritten the file
            -- around the few lines you meant to change.
            { "x", "<Leader>gk", keep_selection, { desc = "Keep the selected lines, revert the rest of the file" } },
            { "n", "<Leader>gw", unformat, { desc = "Revert the whitespace-only changes in this file" } },
          },
          diff3 = merge,
          diff4 = merge,
          file_panel = {
            { "n", "q", close, { desc = "Close the diff" } },
            {
              "n",
              "?",
              function() require("user.diff_keys").toggle() end,
              { desc = "Show or hide the key legend" },
            },

            { "n", "gf", leave "edit", { desc = "Leave the review and open this file here" } },
            { "n", "<C-w><C-f>", leave "split", { desc = "Leave the review and open this file in a split" } },
            { "n", "<C-w>gf", leave "tab", { desc = "Leave the review and open this file in a new tab" } },

            -- The panel is where the review opens, so these have to work from
            -- here. The conflict actions already act on the diff whatever has
            -- focus; navigation needs taking there first.
            { "n", "n", panel_nav(false), { desc = "Next change or conflict, in the diff" } },
            { "n", "N", panel_nav(true), { desc = "Previous change or conflict, in the diff" } },
            -- Whole-file variants: the panel points at a file rather than at a
            -- conflict, and these open it first. `X` is Diffview's own restore
            -- key here, which the review blocks below.
            { "n", "H", take_side("ours", true), { desc = "Take OURS for the file under the cursor" } },
            { "n", "L", take_side("theirs", true), { desc = "Take THEIRS for the file under the cursor" } },
            { "n", "B", take_side("all", true), { desc = "Take both sides for the file under the cursor" } },

            { "n", "-", blocked, { desc = "Staging disabled during safe review" } },
            { "n", "s", blocked, { desc = "Staging disabled during safe review" } },
            { "n", "S", blocked, { desc = "Staging disabled during safe review" } },
            { "n", "U", blocked, { desc = "Staging disabled during safe review" } },
            { "n", "X", review.block_restore, { desc = "Use R in the diff for a pending whole-file revert" } },
          },
          file_history_panel = {
            { "n", "q", close, { desc = "Close the history" } },
            { "n", "gf", leave "edit", { desc = "Leave the history and open this file here" } },
            { "n", "<C-w><C-f>", leave "split", { desc = "Leave the history and open this file in a split" } },
            { "n", "<C-w>gf", leave "tab", { desc = "Leave the history and open this file in a new tab" } },
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
          local line = vim.api.nvim_win_get_cursor(0)[1]
          vim.cmd(("DiffviewFileHistory -L %d,%d:%s"):format(line, line, vim.fn.fnameescape(file)))
        end,
        desc = "History of this line",
      }
      maps.x = maps.x or {}
      maps.x["<Leader>gh"] = {
        function()
          local file = vim.api.nvim_buf_get_name(0)
          if file == "" or vim.bo.buftype ~= "" then return notify "No file in this window" end
          local first, last = vim.fn.line "v", vim.fn.line "."
          if first > last then
            first, last = last, first
          end
          vim.cmd(("DiffviewFileHistory -L %d,%d:%s"):format(first, last, vim.fn.fnameescape(file)))
        end,
        desc = "History of selected lines",
      }
      maps.n["<Leader>gH"] = { "<Cmd>DiffviewFileHistory<CR>", desc = "History of the repository" }
      maps.n["<Leader>gb"] = {
        function() require("gitsigns").toggle_current_line_blame() end,
        desc = "Toggle current-line blame",
      }
      maps.n["<Leader>gB"] =
        { function() require("gitsigns").blame_line { full = true } end, desc = "Full blame for line" }

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
