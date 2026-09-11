local M = {}

---@class DiffReviewSnapshot
---@field buf integer
---@field name string
---@field lines string[]
---@field modified boolean
---@field endofline boolean
---@field autosave boolean?
---@field autoformat boolean?
---@field readonly boolean
---@field disk string
---@field tick integer

---@class DiffReviewSession
---@field view table
---@field buffers table<integer, DiffReviewSnapshot>
---@field finishing boolean
---@field explained boolean? whether the hold has been explained once already

---@type table<table, DiffReviewSession>
local sessions = setmetatable({}, { __mode = "k" })

---@type DiffReviewSession[]
local orphans = {}

---@type table<integer, DiffReviewSession>
local protected = {}

local writing = false

---@param msg string
---@param level? integer
local function notify(msg, level)
  require("astrocore").notify(msg, level or vim.log.levels.WARN, { title = "Diff review" })
end

---@param buf integer
---@return boolean
local function is_file_buffer(buf)
  if not (vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf)) then return false end
  local name = vim.api.nvim_buf_get_name(buf)
  return vim.bo[buf].buftype == "" and name ~= "" and not name:find("://", 1, true)
end

---A stronger version of mtime+size: an outside writer changing equally-sized
---text in the same second must still stop the review from overwriting it.
---@param name string
---@return string
local function disk_state(name)
  local stat = (vim.uv or vim.loop).fs_stat(name)
  if not stat then return "missing" end
  local mtime = stat.mtime or {}
  return table.concat({
    stat.dev or "",
    stat.ino or "",
    stat.size or "",
    mtime.sec or "",
    mtime.nsec or "",
  }, ":")
end

---@param view table?
---@return boolean
local function is_worktree_view(view)
  if not (view and view.right) then return false end
  local ok, rev = pcall(require, "diffview.vcs.rev")
  return ok and view.right.type == rev.RevType.LOCAL
end

---@return table?
local function current_view()
  local ok, lib = pcall(require, "diffview.lib")
  return ok and lib.get_current_view() or nil
end

---Read at call time rather than stored: Diffview only builds the merge context
---once it has found a conflicted file, which can be after the first file of the
---review is already being tracked.
---@param session DiffReviewSession
---@return boolean
local function is_merge(session) return session.view ~= nil and session.view.merge_ctx ~= nil end

---@param snap DiffReviewSnapshot
---@return integer conflict regions still in the buffer
local function markers(snap)
  local ok, hud = pcall(require, "user.diff_hud")
  return ok and hud.conflicts(snap.buf) or 0
end

---Run git and wait. Never a shell: a path can contain a space and argv has no
---quoting to get wrong.
---@param args string[]
---@param cwd string
---@return boolean ok, string output
local function git(args, cwd)
  local cmd = { "git" }
  vim.list_extend(cmd, args)
  local res = vim.system(cmd, { cwd = cwd, text = true }):wait()
  return res.code == 0, vim.trim((res.stdout or "") .. (res.stderr or ""))
end

---@param session DiffReviewSession
---@return string? repository root
local function toplevel(session)
  local adapter = session.view and session.view.adapter
  local root = adapter and adapter.ctx and adapter.ctx.toplevel
  if root and root ~= "" then return root end
  local dot = vim.fs.find(".git", { path = vim.fn.getcwd(), upward = true })[1]
  return dot and vim.fs.dirname(dot) or nil
end

---@param view table
---@return DiffReviewSession?
local function ensure_session(view)
  if not is_worktree_view(view) then return nil end
  if not sessions[view] then sessions[view] = { view = view, buffers = {}, finishing = false } end
  return sessions[view]
end

---@param snap DiffReviewSnapshot
---@return boolean
local function snapshot_changed(snap)
  if not vim.api.nvim_buf_is_valid(snap.buf) or not vim.api.nvim_buf_is_loaded(snap.buf) then return false end
  if vim.bo[snap.buf].endofline ~= snap.endofline then return true end
  if vim.b[snap.buf].changedtick == snap.tick then return false end
  return not vim.deep_equal(vim.api.nvim_buf_get_lines(snap.buf, 0, -1, true), snap.lines)
end

---@param session DiffReviewSession
---@return DiffReviewSnapshot[]
local function pending(session)
  local result = {}
  for _, snap in pairs(session.buffers) do
    if snapshot_changed(snap) then result[#result + 1] = snap end
  end
  table.sort(result, function(a, b) return a.name < b.name end)
  return result
end

---Begin protecting an editable buffer before a review action touches it.
---The diff hook calls this when each file first appears, which also covers
---ordinary insert-mode editing in the YOURS pane.
---@param buf integer
---@return boolean
function M.track(buf)
  if not is_file_buffer(buf) then return false end
  local view = current_view()
  local session = view and ensure_session(view) or nil
  if not session then return false end
  if protected[buf] and protected[buf] ~= session then
    notify "This file already belongs to another open safe review; finish that review first"
    return false
  end

  if not session.buffers[buf] then
    session.buffers[buf] = {
      buf = buf,
      name = vim.api.nvim_buf_get_name(buf),
      lines = vim.api.nvim_buf_get_lines(buf, 0, -1, true),
      modified = vim.bo[buf].modified,
      endofline = vim.bo[buf].endofline,
      autosave = vim.b[buf].autosave,
      autoformat = vim.b[buf].autoformat,
      readonly = vim.bo[buf].readonly,
      disk = disk_state(vim.api.nvim_buf_get_name(buf)),
      tick = vim.b[buf].changedtick,
    }
  end

  -- These are buffer-local, so BufLeave, FocusLost and edits made through an
  -- LSP cannot leak a pending review to disk. `forget` restores the exact
  -- previous values, including nil (inherit the global default).
  vim.b[buf].autosave = false
  vim.b[buf].autoformat = false
  -- `readonly` is what actually holds a write back. An error thrown from
  -- `BufWritePre` only aborts writes issued through the API; a `:w` typed on
  -- the command line reports the error and writes the file anyway. E45 comes
  -- from `:write` itself, before any autocommand, so it stops both.
  vim.bo[buf].readonly = true
  protected[buf] = session
  return true
end

---Has this buffer diverged from the state in which the review first showed it?
---Used to keep review-local `u` from reaching backwards into edits that existed
---before Diffview was opened.
---@param buf integer
---@return boolean
function M.changed(buf)
  local view = current_view()
  local session = view and sessions[view] or nil
  local snap = session and session.buffers[buf] or nil
  return snap ~= nil and snapshot_changed(snap)
end

---Was this buffer writable before the review put its hold on it? The hold
---itself sets `readonly`, so the live option cannot answer this.
---@param buf integer
---@return boolean
function M.writable(buf)
  local session = protected[buf]
  local snap = session and session.buffers[buf] or nil
  if snap then return not snap.readonly end
  return not vim.bo[buf].readonly
end

---@param session DiffReviewSession
local function unprotect(session)
  for _, snap in pairs(session.buffers) do
    if protected[snap.buf] == session then
      if vim.api.nvim_buf_is_valid(snap.buf) then
        vim.b[snap.buf].autosave = snap.autosave
        vim.b[snap.buf].autoformat = snap.autoformat
        vim.bo[snap.buf].readonly = snap.readonly
      end
      protected[snap.buf] = nil
    end
  end
end

---@param session DiffReviewSession
local function forget(session)
  unprotect(session)
  sessions[session.view] = nil
  for i = #orphans, 1, -1 do
    if orphans[i] == session then table.remove(orphans, i) end
  end
end

---Git counts a resolved file as still unmerged until it is staged, so writing
---one during a merge is only half of finishing with it.
---@param session DiffReviewSession
---@param written DiffReviewSnapshot[]
local function stage(session, written)
  local root = toplevel(session)
  if not root then return notify "Written, but the repository root is unknown -- stage the files in Neogit" end

  local failed = {}
  for _, snap in ipairs(written) do
    local ok = git({ "add", "--", snap.name }, root)
    if not ok then failed[#failed + 1] = vim.fn.fnamemodify(snap.name, ":~:.") end
  end
  if #failed > 0 then
    notify(("Written, but not staged: %s"):format(table.concat(failed, ", ")), vim.log.levels.ERROR)
  end
end

---The commit belongs to Neogit: it opens git's own prepared merge message in a
---buffer to confirm, which is not something a diff view should invent.
local function finish_merge()
  local loaded, neogit = pcall(require, "neogit")
  if not (loaded and type(neogit.action) == "function") then
    return notify "Saved and staged. Neogit is not available, so commit the merge yourself"
  end
  local ran = pcall(neogit.action("merge", "commit", {}))
  if not ran then notify "Saved and staged, but Neogit could not continue the merge -- try :Neogit" end
end

---A merge resolution is the one review where nothing on screen has said what
---the result will look like as a change: the panes compare it to each side,
---not to the branch. So what is staged is shown as an ordinary review, and
---closing that is what hands the commit on.
---@param session DiffReviewSession
local function finish_pass(session)
  local root = toplevel(session)
  if not root then return finish_merge() end
  -- Nothing staged is nothing to read, and no reason to hold up the commit.
  local listed, out = git({ "diff", "--cached", "--name-only" }, root)
  if not (listed and out ~= "") then return finish_merge() end

  local opened = pcall(vim.cmd, "DiffviewOpen --cached")
  if not opened then return finish_merge() end
  notify "This is what the merge commit will contain -- q goes on to the commit message"

  vim.api.nvim_create_autocmd("User", {
    pattern = "DiffviewViewClosed",
    group = vim.api.nvim_create_augroup("diff_review_finish", { clear = true }),
    once = true,
    desc = "Commit the merge once the staged changes have been read",
    callback = function() vim.schedule(finish_merge) end,
  })
end

---@param session DiffReviewSession
---@return boolean
local function save(session)
  local changed = pending(session)

  -- A file with conflict markers still in it is not a resolution, and this is
  -- the one place that decides what reaches disk.
  local held = {}
  if is_merge(session) then
    local resolved = {}
    for _, snap in ipairs(changed) do
      local list = markers(snap) > 0 and held or resolved
      list[#list + 1] = snap
    end
    changed = resolved
    if #changed == 0 then
      notify(
        ("Nothing written: %d file%s still %s conflict markers. n and N jump to what is left"):format(
          #held,
          #held == 1 and "" or "s",
          #held == 1 and "has" or "have"
        )
      )
      return false
    end
  end

  -- Preflight every file before writing the first one. This is not a filesystem
  -- transaction, but it prevents the ordinary partial-save failure: an editor,
  -- formatter, checkout or pull changing one of the files during the review.
  for _, snap in ipairs(changed) do
    if disk_state(snap.name) ~= snap.disk then
      notify(
        ("Save stopped: %s changed on disk while the review was open. Your pending buffer is still intact."):format(
          vim.fn.fnamemodify(snap.name, ":~:.")
        ),
        vim.log.levels.ERROR
      )
      return false
    end
  end

  for _, snap in ipairs(changed) do
    writing = true
    vim.bo[snap.buf].readonly = false
    local ok, err = pcall(vim.api.nvim_buf_call, snap.buf, function() vim.cmd "silent write" end)
    -- Re-armed rather than left off: a failed save keeps the review open, and
    -- the files it did write are still under review until the session ends.
    vim.bo[snap.buf].readonly = true
    writing = false
    if not ok then
      notify(("Save failed; the review remains open: %s"):format(err), vim.log.levels.ERROR)
      return false
    end

    -- If a later write fails, files already written are no longer reported as
    -- pending and will not be written a second time on the next attempt.
    snap.lines = vim.api.nvim_buf_get_lines(snap.buf, 0, -1, true)
    snap.endofline = vim.bo[snap.buf].endofline
    snap.modified = false
    snap.disk = disk_state(snap.name)
    snap.tick = vim.b[snap.buf].changedtick
  end

  if is_merge(session) then stage(session, changed) end
  notify(("Saved review changes in %d file%s"):format(#changed, #changed == 1 and "" or "s"), vim.log.levels.INFO)

  if is_merge(session) then
    local ok, hud = pcall(require, "user.diff_hud")
    local left = ok and hud.unresolved(session.view) or 0
    -- Files nobody edited are not at risk, so this is a reminder rather than a
    -- reason to keep the review open.
    if left > 0 and #held == 0 then
      notify(("%d conflicted file%s left to resolve -- reopen with <Leader>gd"):format(left, left == 1 and "" or "s"))
    end
  end

  -- Reporting false keeps the review open, which is the only safe answer: the
  -- files that still have markers are unwritten, and closing would drop the
  -- hold that is keeping them off disk.
  if #held > 0 then
    notify(
      ("%d file%s still %s conflict markers and stayed in memory -- the review is still open"):format(
        #held,
        #held == 1 and "" or "s",
        #held == 1 and "has" or "have"
      )
    )
    return false
  end
  return true
end

---@param session DiffReviewSession
local function discard(session)
  local changed = pending(session)
  for _, snap in ipairs(changed) do
    if vim.api.nvim_buf_is_valid(snap.buf) and vim.api.nvim_buf_is_loaded(snap.buf) then
      vim.api.nvim_buf_set_lines(snap.buf, 0, -1, true, snap.lines)
      vim.bo[snap.buf].endofline = snap.endofline
      -- Preserve an unsaved buffer that existed before Diffview. Setting this
      -- after the line replacement distinguishes it from the review edits.
      vim.bo[snap.buf].modified = snap.modified
    end
  end
  notify(("Discarded review changes in %d file%s"):format(#changed, #changed == 1 and "" or "s"), vim.log.levels.INFO)
end

---@param session DiffReviewSession
---@param allow_cancel boolean
---@return boolean finished, boolean? continuing into a staged pass
local function prompt(session, allow_cancel)
  local count = #pending(session)
  if count == 0 then
    forget(session)
    return true
  end

  local message = ("Diff review has pending changes in %d file%s.\nNothing has been written yet."):format(
    count,
    count == 1 and "" or "s"
  )

  -- Finishing the merge is only offered once every file is actually resolved,
  -- because `git merge --continue` refuses while any path is unmerged -- and
  -- that includes conflicted files this review never opened.
  local left = 0
  if is_merge(session) then
    local ok, hud = pcall(require, "user.diff_hud")
    left = ok and hud.unresolved(session.view) or 0
    message = message
      .. (
        left > 0
          and ("\n%d conflicted file%s still %s markers and will not be written."):format(
            left,
            left == 1 and "" or "s",
            left == 1 and "has" or "have"
          )
        or "\nEvery conflict is resolved: saving stages the files as well."
      )
  end

  local offer_finish = is_merge(session) and left == 0
  local last = allow_cancel and "&Cancel" or "&Keep pending"
  local buttons = offer_finish and ("&Save\nSave and &finish\n&Discard\n" .. last) or ("&Save\n&Discard\n" .. last)
  local choice = vim.fn.confirm(message, buttons, offer_finish and 4 or 3, "Question")

  local finish = offer_finish and choice == 2
  if choice == 1 or finish then
    if not save(session) then return false end
    -- Scheduled so it runs after this view has closed: the staged review needs
    -- the tab to itself, and Diffview only keeps one view per tab.
    if finish then vim.schedule(function() finish_pass(session) end) end
  elseif choice == (offer_finish and 3 or 2) then
    discard(session)
  else
    return false
  end

  forget(session)
  return true, finish
end

local function raw_close() require("diffview").close() end

---The only normal exit from a working-tree review. File-history views have no
---editable local side and therefore close without a transaction prompt.
---
---"Save and finish" schedules a staged review to open in this tab, so anything
---waiting to act on the closed review has to know not to take the tab as well.
---@return boolean closed, boolean? continuing into a staged pass
function M.close()
  local view = current_view()
  local session = view and sessions[view] or nil
  if session then
    local closed, finishing = prompt(session, true)
    if not closed then return false end
    raw_close()
    return true, finishing
  end
  raw_close()
  return true
end

---Called after an unexpected close such as `:tabclose`. The ordinary `q` and
---`:DiffviewClose` paths prompt before closing; this is the final safety net.
---@param view table
function M.closed(view)
  local session = sessions[view]
  if not session or session.finishing then return end
  if #pending(session) == 0 then return forget(session) end

  orphans[#orphans + 1] = session
  vim.schedule(function()
    if prompt(session, false) then return end
    notify "Review edits are still pending and protected from autosave. Run :DiffReviewFinish to decide later."
  end)
end

---Finish a review that was closed through `:tabclose` or another raw tab action.
function M.finish()
  local session = orphans[#orphans]
  if not session then return notify("There is no closed review with pending changes", vim.log.levels.INFO) end
  prompt(session, false)
end

---Replace Diffview's public close command so typed commands receive the same
---guard as `q`. The module's `raw_close()` calls the Lua API and cannot recurse.
function M.install_close_command()
  pcall(vim.api.nvim_del_user_command, "DiffviewClose")
  vim.api.nvim_create_user_command(
    "DiffviewClose",
    M.close,
    { desc = "Close Diffview, resolving pending review edits" }
  )
  pcall(vim.api.nvim_del_user_command, "DiffReviewFinish")
  vim.api.nvim_create_user_command("DiffReviewFinish", M.finish, {
    desc = "Resolve edits from a safe review whose tab was closed directly",
  })
end

function M.block_index_change()
  local view = current_view()
  local session = view and sessions[view] or nil
  -- A merge review does stage, but on Save, so that writing and staging cannot
  -- come apart -- an unstaged resolution is still an unmerged path to git.
  if session and is_merge(session) then
    return notify "Resolve the conflicts and press q -- Save writes and stages them together"
  end
  notify "Staging is disabled during a safe review; save or discard it first, then stage normally"
end

function M.block_restore() notify "Use R in the diff pane so the whole-file revert stays pending until the exit prompt" end

function M.block_history_restore()
  notify "Restoring a historical file writes immediately, so it is disabled in safe review mode"
end

local write_guard = vim.api.nvim_create_augroup("diff_review_write_guard", { clear = true })

vim.api.nvim_create_autocmd("FileChangedRO", {
  group = write_guard,
  desc = "Say why a review buffer refuses to be written",
  callback = function(args)
    local session = protected[args.buf]
    -- Once per review: every revert in every file trips this, and the W10 that
    -- Neovim prints after it is reminder enough from the second time on.
    if not session or session.explained then return end
    session.explained = true
    notify "Edits here stay in memory -- press q and choose Save to write them. The W10 warning is that hold"
  end,
})

vim.api.nvim_create_autocmd("BufWritePost", {
  group = write_guard,
  desc = "Account for a review file written past the hold with :w!",
  callback = function(args)
    local session = protected[args.buf]
    local snap = session and session.buffers[args.buf] or nil
    if not snap or writing then return end

    -- `:w!` clears `readonly`, so the hold has to be put back for the rest of
    -- the review, and this file counted as written rather than still pending.
    vim.bo[args.buf].readonly = true
    snap.lines = vim.api.nvim_buf_get_lines(args.buf, 0, -1, true)
    snap.endofline = vim.bo[args.buf].endofline
    snap.modified = false
    snap.disk = disk_state(snap.name)
    snap.tick = vim.b[args.buf].changedtick
    local name = vim.fn.fnamemodify(snap.name, ":~:.")
    if markers(snap) > 0 then
      return notify(("%s is written WITH conflict markers still in it"):format(name), vim.log.levels.ERROR)
    end
    notify(("%s is written; the rest of the review is still pending"):format(name), vim.log.levels.INFO)
  end,
})

return M
