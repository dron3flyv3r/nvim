---@param message string
---@param level? integer
local function say(message, level) vim.notify(message, level or vim.log.levels.WARN, { title = "Git" }) end

---@param module string
---@param fn string
---@return fun()
local function call(module, fn)
  return function() require("plugins.git." .. module)[fn]() end
end

---@return string?
local function repository()
  local cwd = vim.uv.cwd()
  return cwd and vim.fs.root(cwd, ".git") or nil
end

local function diff_against_ref()
  local root = repository()
  if not root then return say "Not in a git repository" end
  local res = vim.system({
    "git",
    "for-each-ref",
    "--sort=-committerdate",
    "--format=%(refname:short)",
    "refs/heads",
    "refs/remotes",
  }, { cwd = root, text = true }):wait()
  if res.code ~= 0 then return say(vim.trim(res.stderr or "git for-each-ref failed")) end

  local refs = vim.split(vim.trim(res.stdout or ""), "\n", { trimempty = true })
  if #refs == 0 then return say "No branches to diff against" end
  vim.ui.select(refs, { prompt = "Diff against" }, function(ref)
    if ref then vim.cmd("DiffviewOpen " .. ref) end
  end)
end

---@param first integer
---@param last integer
local function file_history(first, last)
  local file = vim.api.nvim_buf_get_name(0)
  if file == "" or vim.bo.buftype ~= "" then
    return say "No file in this window -- <Leader>gH is the history of the repository"
  end
  vim.cmd(("DiffviewFileHistory -L %d,%d:%s"):format(first, last, vim.fn.fnameescape(file)))
end

local function history_of_line()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  file_history(lnum, lnum)
end

local function history_of_selection()
  local first, last = vim.fn.line "v", vim.fn.line "."
  if first > last then
    first, last = last, first
  end
  vim.cmd "normal! \27"
  file_history(first, last)
end

-- The buffer Diffview shows when every file in a review has been reverted. It is
-- the one buffer Diffview does not hand its keymaps to, hence the autocommand.
---@param buf integer
local function dress_empty_view(buf)
  vim.keymap.set("n", "q", "<Cmd>DiffviewClose<CR>", { buffer = buf, nowait = true, desc = "Close the diff" })
  -- `BufWinEnter` does not say which window, and both panes show this buffer.
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == buf then require("plugins.git.hud").dress_empty(win) end
  end
end

local function diffview_opts()
  local review = require "plugins.git.review"
  local conflicts = require "plugins.git.conflicts"
  local nav = require "plugins.git.nav"
  local leave = require("plugins.git.goto").leave
  local close = function() review.close() end
  local legend = function() require("plugins.git.keys").toggle() end

  -- Attached only in the three- and four-pane merge layouts, where they win over
  -- the `view` maps below. That is what lets `n` mean conflicts here and changes
  -- everywhere else without a mode check.
  local merge = {
    { "n", "H", conflicts.take "ours", { desc = "Take OURS, the left pane" } },
    { "n", "L", conflicts.take "theirs", { desc = "Take THEIRS, the right pane" } },
    { "n", "B", conflicts.take "all", { desc = "Take both sides, ours first" } },
    { "n", "X", conflicts.take "none", { desc = "Drop both sides" } },
    { "n", "gH", conflicts.take("ours", true), { desc = "Take OURS for the whole file" } },
    { "n", "gL", conflicts.take("theirs", true), { desc = "Take THEIRS for the whole file" } },
    { "n", "gB", conflicts.take("all", true), { desc = "Take both sides for the whole file" } },
    { "n", "<Leader>cb", conflicts.show_base, { desc = "Show BASE, the common ancestor of this conflict" } },

    -- The same key in both modes, so one line is one press and several lines are
    -- a selection.
    { "n", "<CR>", conflicts.take_lines(false), { desc = "Take this line into the resolution" } },
    { "x", "<CR>", conflicts.take_lines(true), { desc = "Take the selected lines into the resolution" } },

    { "n", "]r", conflicts.nav_resolution(false), { desc = "Next resolution, to check it" } },
    { "n", "[r", conflicts.nav_resolution(true), { desc = "Previous resolution, to check it" } },
    { "n", "<Tab>", conflicts.next_file, { desc = "Next file with conflicts left in it" } },

    { "n", "n", conflicts.nav_conflict(false), { desc = "Next conflict" } },
    { "n", "N", conflicts.nav_conflict(true), { desc = "Previous conflict" } },
    { "n", "]c", conflicts.nav_conflict(false), { desc = "Next conflict" } },
    { "n", "[c", conflicts.nav_conflict(true), { desc = "Previous conflict" } },

    { "n", "r", conflicts.hint(false), { desc = "Reverting is H or L in a merge" } },
    { "n", "R", conflicts.hint(true), { desc = "Reverting is gH or gL in a merge" } },
    { "n", "<Leader>gr", conflicts.hint(false), { desc = "Reverting is H or L in a merge" } },
    { "n", "<Leader>gl", conflicts.hint(false), { desc = "Reverting is H or L in a merge" } },
    { "n", "<Leader>gR", conflicts.hint(true), { desc = "Reverting is gH or gL in a merge" } },
    { "x", "<Leader>gr", conflicts.hint(false), { desc = "Reverting is H or L in a merge" } },
    { "x", "<Leader>gk", conflicts.hint(false), { desc = "Keeping lines is <CR> in a merge" } },
    { "n", "<Leader>gw", conflicts.hint(false), { desc = "There is no formatting to undo in a merge" } },
  }

  return {
    -- Off because `diffopt` already carries `inline:char` on this nightly, which
    -- is the same word-level highlight done natively.
    enhanced_diff_hl = false,
    view = {
      default = { layout = "diff2_horizontal", winbar_info = false },
      -- Three panes, not `diff4_mixed`: the RESULT pane is the one being edited
      -- and it keeps full height. BASE is <Leader>cb away.
      merge_tool = { layout = "diff3_horizontal", disable_diagnostics = true, winbar_info = false },
      file_history = { layout = "diff2_horizontal", winbar_info = false },
    },
    file_panel = {
      listing_style = "tree",
      tree_options = { flatten_dirs = true, folder_statuses = "only_folded" },
      win_config = { position = "left", width = 35 },
    },
    hooks = {
      diff_buf_win_enter = function(bufnr, winid, ctx)
        require("plugins.git.hud").dress(bufnr, winid, ctx)
        review.track(bufnr)
        require("plugins.git.keys").show(require("plugins.git.hud").current_kind())
      end,
      view_closed = function(view)
        require("plugins.git.hud").closed()
        review.closed(view)
        require("plugins.git.keys").hide()
        -- Scheduled: the detach that deletes the keymaps has not happened yet.
        vim.schedule(function() require("plugins.git.signs").remap() end)
      end,
    },
    keymaps = {
      -- Defaults stay on for motions, folds and `g?` help. Mutating git's index
      -- is overridden below because it cannot take part in the review's
      -- in-memory transaction.
      view = {
        { "n", "q", close, { desc = "Close the diff" } },
        { "n", "?", legend, { desc = "Show or hide the key legend" } },

        -- Bound in `view` so the merge layouts inherit them too.
        { "n", "gf", leave "edit", { desc = "Leave the review and open this file here" } },
        { "n", "<C-w><C-f>", leave "split", { desc = "Leave the review and open this file in a split" } },
        { "n", "<C-w>gf", leave "tab", { desc = "Leave the review and open this file in a new tab" } },

        { "n", "n", nav.change(false), { desc = "Next change (into the next file)" } },
        { "n", "N", nav.change(true), { desc = "Previous change (into the previous file)" } },
        { "n", "]c", nav.change(false), { desc = "Next change (into the next file)" } },
        { "n", "[c", nav.change(true), { desc = "Previous change (into the previous file)" } },

        { "n", "u", call("revert", "undo"), { desc = "Undo the last revert" } },
        { "n", "r", call("revert", "hunk"), { desc = "Revert this change (pending)" } },
        { "n", "R", call("revert", "file"), { desc = "Revert this file (pending)" } },
        { "n", "<Leader>gr", call("revert", "hunk"), { desc = "Revert this change" } },
        { "x", "<Leader>gr", call("revert", "selection"), { desc = "Revert the selected lines" } },
        { "n", "<Leader>gl", call("revert", "line"), { desc = "Revert this line only" } },
        { "n", "<Leader>gR", call("revert", "file"), { desc = "Revert the whole file (pending)" } },

        { "x", "<Leader>gk", call("revert", "keep_selection"), { desc = "Keep these lines, revert the rest" } },
        { "n", "<Leader>gw", call("revert", "unformat"), { desc = "Revert the whitespace-only changes" } },
      },
      diff3 = merge,
      diff4 = merge,
      file_panel = {
        { "n", "q", close, { desc = "Close the diff" } },
        { "n", "?", legend, { desc = "Show or hide the key legend" } },

        { "n", "gf", leave "edit", { desc = "Leave the review and open this file here" } },
        { "n", "<C-w><C-f>", leave "split", { desc = "Leave the review and open this file in a split" } },
        { "n", "<C-w>gf", leave "tab", { desc = "Leave the review and open this file in a new tab" } },

        -- The review opens here, so these have to work from the panel. The
        -- conflict actions already act on the diff whatever has focus;
        -- navigation needs taking there first.
        { "n", "n", nav.panel(false), { desc = "Next change or conflict, in the diff" } },
        { "n", "N", nav.panel(true), { desc = "Previous change or conflict, in the diff" } },
        { "n", "H", conflicts.take("ours", true), { desc = "Take OURS for the file under the cursor" } },
        { "n", "L", conflicts.take("theirs", true), { desc = "Take THEIRS for the file under the cursor" } },
        { "n", "B", conflicts.take("all", true), { desc = "Take both sides for the file under the cursor" } },

        { "n", "-", review.block_index_change, { desc = "Staging is disabled during a review" } },
        { "n", "s", review.block_index_change, { desc = "Staging is disabled during a review" } },
        { "n", "S", review.block_index_change, { desc = "Staging is disabled during a review" } },
        { "n", "U", review.block_index_change, { desc = "Staging is disabled during a review" } },
        { "n", "X", review.block_restore, { desc = "Use R in the diff for a pending whole-file revert" } },
      },
      file_history_panel = {
        { "n", "q", close, { desc = "Close the history" } },
        { "n", "gf", leave "edit", { desc = "Leave the history and open this file here" } },
        { "n", "<C-w><C-f>", leave "split", { desc = "Leave the history and open this file in a split" } },
        { "n", "<C-w>gf", leave "tab", { desc = "Leave the history and open this file in a new tab" } },
        { "n", "X", review.block_history_restore, { desc = "Restoring is disabled during a review" } },
      },
    },
  }
end

---@type LazySpec
return {
  {
    "lewis6991/gitsigns.nvim",
    event = { "BufReadPre", "BufNewFile" },
    opts = function() return require("plugins.git.signs").opts() end,
    config = function(_, opts)
      require("gitsigns").setup(opts)
      require("plugins.git.status").setup()
    end,
  },

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
    keys = {
      { "<Leader>gd", "<Cmd>DiffviewOpen<CR>", desc = "Diff all changes" },
      { "<Leader>gD", diff_against_ref, desc = "Diff against a branch" },
      { "<Leader>gh", history_of_line, desc = "History of this line" },
      { "<Leader>gh", history_of_selection, mode = "x", desc = "History of the selected lines" },
      { "<Leader>gH", "<Cmd>DiffviewFileHistory<CR>", desc = "History of the repository" },
    },
    opts = diffview_opts,
    config = function(_, opts)
      require("diffview").setup(opts)
      require("plugins.git.hud").setup()
      require("plugins.git.keys").setup()
      require("plugins.git.review").setup()

      vim.api.nvim_create_autocmd("BufWinEnter", {
        group = vim.api.nvim_create_augroup("git_empty_view", { clear = true }),
        pattern = "diffview://null",
        desc = "Let `q` close a diff view with nothing left in it",
        callback = function(args) dress_empty_view(args.buf) end,
      })
    end,
  },

  {
    "NeogitOrg/neogit",
    -- Four commands, not one: `cmd = "Neogit"` would leave the other three
    -- undefined until something else happened to load the plugin.
    cmd = { "Neogit", "NeogitResetState", "NeogitLogCurrent", "NeogitCommit" },
    -- Two keys only: everything else Neogit does is a single letter from its own
    -- status buffer, and duplicating those here would be a second set of names.
    keys = {
      { "<Leader>gg", "<Cmd>Neogit<CR>", desc = "Git status (Neogit)" },
      { "<Leader>gm", "<Cmd>Neogit merge<CR>", desc = "Merge, or continue an unfinished one" },
    },
    opts = {
      -- Stated rather than left to Neogit's auto-detection, which probes with
      -- `require` and would silently pick up whatever happens to be installed.
      integrations = { diffview = true, snacks = true, telescope = false, fzf_lua = false, mini_pick = false },
      -- A split rather than a tab: the commit message is written against the
      -- staged diff, and a new tab hides the review it came from.
      commit_editor = { kind = "split", show_staged_diff = true },
      merge_editor = { kind = "split" },
    },
  },
}
