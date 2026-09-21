local M = {}

---@class git.review.Snapshot
---@field buf integer
---@field name string
---@field lines string[]
---@field modified boolean
---@field endofline boolean
---@field readonly boolean
---@field disk string
---@field tick integer

---@class git.review.Session
---@field view table
---@field buffers table<integer, git.review.Snapshot>
---@field finishing boolean
---@field explained boolean?

---@type table<table, git.review.Session>
local sessions = setmetatable({}, { __mode = "k" })

---@type git.review.Session[]
local orphans = {}

---@type table<integer, git.review.Session>
local protected = {}

local writing = false

---@param message string
---@param level? integer
local function say(message, level)
  vim.notify(message, level or vim.log.levels.WARN, { title = "Diff review" })
end

---@param buf integer
---@return boolean
local function is_file_buffer(buf)
  if not (vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf)) then return false end
  local name = vim.api.nvim_buf_get_name(buf)
  return vim.bo[buf].buftype == "" and name ~= "" and not name:find("://", 1, true)
end

-- Stronger than mtime and size: an outside writer changing equally-sized text in
-- the same second must still stop the review from overwriting it.
---@param name string
---@return string
local function disk_state(name)
  local stat = vim.uv.fs_stat(name)
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

-- Read at call time rather than stored: Diffview only builds the merge context
-- once it has found a conflicted file, which can be after the first file of the
-- review is already tracked.
---@param session git.review.Session
---@return boolean
local function is_merge(session) return session.view ~= nil and session.view.merge_ctx ~= nil end

---@param snap git.review.Snapshot
---@return integer
local function markers(snap)
  local ok, hud = pcall(require, "plugins.git.hud")
  return ok and hud.conflicts(snap.buf) or 0
end

---@param args string[]
---@param cwd string
---@return boolean ok, string output
local function git(args, cwd)
  local cmd = { "git" }
  vim.list_extend(cmd, args)
  local res = vim.system(cmd, { cwd = cwd, text = true }):wait()
  return res.code == 0, vim.trim((res.stdout or "") .. (res.stderr or ""))
end

---@param session git.review.Session
---@return string?
local function toplevel(session)
  local adapter = session.view and session.view.adapter
  local root = adapter and adapter.ctx and adapter.ctx.toplevel
  if root and root ~= "" then return root end
  local dot = vim.fs.find(".git", { path = vim.fn.getcwd(), upward = true })[1]
  return dot and vim.fs.dirname(dot) or nil
end

---@param view table
---@return git.review.Session?
local function ensure_session(view)
  if not is_worktree_view(view) then return nil end
  if not sessions[view] then sessions[view] = { view = view, buffers = {}, finishing = false } end
  return sessions[view]
end

---@param snap git.review.Snapshot
---@return boolean
local function snapshot_changed(snap)
  if not (vim.api.nvim_buf_is_valid(snap.buf) and vim.api.nvim_buf_is_loaded(snap.buf)) then return false end
  if vim.bo[snap.buf].endofline ~= snap.endofline then return true end
  if vim.b[snap.buf].changedtick == snap.tick then return false end
  return not vim.deep_equal(vim.api.nvim_buf_get_lines(snap.buf, 0, -1, true), snap.lines)
end

---@param session git.review.Session
---@return git.review.Snapshot[]
local function pending(session)
  local result = {}
  for _, snap in pairs(session.buffers) do
    if snapshot_changed(snap) then result[#result + 1] = snap end
  end
  table.sort(result, function(a, b) return a.name < b.name end)
  return result
end

---@param buf integer
---@return boolean
function M.track(buf)
  if not is_file_buffer(buf) then return false end
  local view = current_view()
  local session = view and ensure_session(view) or nil
  if not session then return false end
  if protected[buf] and protected[buf] ~= session then
    say "This file already belongs to another open review; finish that review first"
    return false
  end

  if not session.buffers[buf] then
    session.buffers[buf] = {
      buf = buf,
      name = vim.api.nvim_buf_get_name(buf),
      lines = vim.api.nvim_buf_get_lines(buf, 0, -1, true),
      modified = vim.bo[buf].modified,
      endofline = vim.bo[buf].endofline,
      readonly = vim.bo[buf].readonly,
      disk = disk_state(vim.api.nvim_buf_get_name(buf)),
      tick = vim.b[buf].changedtick,
    }
  end

  -- `readonly` is what actually holds a write back. An error thrown from
  -- `BufWritePre` only aborts writes issued through the API; a `:w` typed on the
  -- command line reports the error and writes the file anyway. E45 comes from
  -- `:write` itself, before any autocommand, so it stops both.
  vim.bo[buf].readonly = true
  protected[buf] = session
  return true
end

-- Keeps review-local `u` from reaching backwards into edits that existed before
-- Diffview was opened.
---@param buf integer
---@return boolean
function M.changed(buf)
  local view = current_view()
  local session = view and sessions[view] or nil
  local snap = session and session.buffers[buf] or nil
  return snap ~= nil and snapshot_changed(snap)
end

-- The hold sets `readonly` itself, so the live option cannot answer whether the
-- file was writable before the review.
---@param buf integer
---@return boolean
function M.writable(buf)
  local session = protected[buf]
  local snap = session and session.buffers[buf] or nil
  if snap then return not snap.readonly end
  return not vim.bo[buf].readonly
end

---@param session git.review.Session
local function unprotect(session)
  for _, snap in pairs(session.buffers) do
    if protected[snap.buf] == session then
      if vim.api.nvim_buf_is_valid(snap.buf) then vim.bo[snap.buf].readonly = snap.readonly end
      protected[snap.buf] = nil
    end
  end
end

---@param session git.review.Session
local function forget(session)
  unprotect(session)
  sessions[session.view] = nil
  for i = #orphans, 1, -1 do
    if orphans[i] == session then table.remove(orphans, i) end
  end
end

-- Git counts a resolved file as still unmerged until it is staged, so writing
-- one during a merge is only half of finishing with it.
---@param session git.review.Session
---@param written git.review.Snapshot[]
local function stage(session, written)
  local root = toplevel(session)
  if not root then return say "Written, but the repository root is unknown -- stage the files in Neogit" end

  local failed = {}
  for _, snap in ipairs(written) do
    local ok = git({ "add", "--", snap.name }, root)
    if not ok then failed[#failed + 1] = vim.fn.fnamemodify(snap.name, ":~:.") end
  end
  if #failed > 0 then say(("Written, but not staged: %s"):format(table.concat(failed, ", ")), vim.log.levels.ERROR) end
end

-- The commit belongs to Neogit: it opens git's own prepared merge message in a
-- buffer to confirm, which is not something a diff view should invent.
local function finish_merge()
  local loaded, neogit = pcall(require, "neogit")
  if not (loaded and type(neogit.action) == "function") then
    return say "Saved and staged. Neogit is not available, so commit the merge yourself"
  end
  local ran = pcall(neogit.action("merge", "commit", {}))
  if not ran then say "Saved and staged, but Neogit could not continue the merge -- try :Neogit" end
end

-- The merge panes compare the resolution to each side, so nothing in the review
-- has shown the merge as a change to your own branch. What is staged is shown as
-- an ordinary review, and closing that is what hands the commit on.
---@param session git.review.Session
local function finish_pass(session)
  local root = toplevel(session)
  if not root then return finish_merge() end
  local listed, out = git({ "diff", "--cached", "--name-only" }, root)
  if not (listed and out ~= "") then return finish_merge() end

  local opened = pcall(vim.cmd, "DiffviewOpen --cached")
  if not opened then return finish_merge() end
  say("This is what the merge commit will contain -- q goes on to the commit message", vim.log.levels.INFO)

  vim.api.nvim_create_autocmd("User", {
    pattern = "DiffviewViewClosed",
    group = vim.api.nvim_create_augroup("git_review_finish", { clear = true }),
    once = true,
    desc = "Commit the merge once the staged changes have been read",
    callback = function() vim.schedule(finish_merge) end,
  })
end

---@param session git.review.Session
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
      say(
        ("Nothing written: %d file%s still %s conflict markers. n and N jump to what is left"):format(
          #held,
          #held == 1 and "" or "s",
          #held == 1 and "has" or "have"
        )
      )
      return false
    end
  end

  -- Not a filesystem transaction, but it prevents the ordinary partial-save
  -- failure: an editor, checkout or pull changing one of the files mid-review.
  for _, snap in ipairs(changed) do
    if disk_state(snap.name) ~= snap.disk then
      say(
        ("Save stopped: %s changed on disk while the review was open. Your pending buffer is intact."):format(
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
      say(("Save failed; the review remains open: %s"):format(err), vim.log.levels.ERROR)
      return false
    end

    -- A file already written is no longer pending, so a later failure does not
    -- write it a second time on the next attempt.
    snap.lines = vim.api.nvim_buf_get_lines(snap.buf, 0, -1, true)
    snap.endofline = vim.bo[snap.buf].endofline
    snap.modified = false
    snap.disk = disk_state(snap.name)
    snap.tick = vim.b[snap.buf].changedtick
  end

  if is_merge(session) then stage(session, changed) end
  say(("Saved review changes in %d file%s"):format(#changed, #changed == 1 and "" or "s"), vim.log.levels.INFO)

  if is_merge(session) then
    local ok, hud = pcall(require, "plugins.git.hud")
    local left = ok and hud.unresolved(session.view) or 0
    -- Files nobody edited are not at risk, so this is a reminder rather than a
    -- reason to keep the review open.
    if left > 0 and #held == 0 then
      say(("%d conflicted file%s left to resolve -- reopen with <Leader>gd"):format(left, left == 1 and "" or "s"))
    end
  end

  -- Reporting false keeps the review open, which is the only safe answer: the
  -- files that still have markers are unwritten, and closing would drop the hold
  -- that is keeping them off disk.
  if #held > 0 then
    say(
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

---@param session git.review.Session
local function discard(session)
  local changed = pending(session)
  for _, snap in ipairs(changed) do
    if vim.api.nvim_buf_is_valid(snap.buf) and vim.api.nvim_buf_is_loaded(snap.buf) then
      vim.api.nvim_buf_set_lines(snap.buf, 0, -1, true, snap.lines)
      vim.bo[snap.buf].endofline = snap.endofline
      -- After the line replacement, which is what distinguishes an unsaved
      -- buffer that existed before Diffview from the review's own edits.
      vim.bo[snap.buf].modified = snap.modified
    end
  end
  say(("Discarded review changes in %d file%s"):format(#changed, #changed == 1 and "" or "s"), vim.log.levels.INFO)
end

---@param session git.review.Session
---@param allow_cancel boolean
---@return boolean finished, boolean? continuing
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

  -- Finishing is only offered once every file is resolved, because `git merge
  -- --continue` refuses while any path is unmerged -- including conflicted files
  -- this review never opened.
  local left = 0
  if is_merge(session) then
    local ok, hud = pcall(require, "plugins.git.hud")
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
    -- the tab to itself, and Diffview keeps one view per tab.
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

-- "Save and finish" schedules a staged review to open in this tab, so anything
-- waiting to act on the closed review has to know not to take the tab as well.
---@return boolean closed, boolean? continuing
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

-- The final safety net, after an unexpected close such as `:tabclose`. The
-- ordinary `q` and `:DiffviewClose` paths prompt before closing.
---@param view table
function M.closed(view)
  local session = sessions[view]
  if not session or session.finishing then return end
  if #pending(session) == 0 then return forget(session) end

  orphans[#orphans + 1] = session
  vim.schedule(function()
    if prompt(session, false) then return end
    say "Review edits are still pending and held off disk. Run :ReviewFinish to decide later."
  end)
end

function M.finish()
  local session = orphans[#orphans]
  if not session then return say("There is no closed review with pending changes", vim.log.levels.INFO) end
  prompt(session, false)
end

-- Diffview's own close command is replaced so a typed command gets the same
-- guard as `q`. `raw_close` calls the Lua API and cannot recurse.
function M.install_commands()
  pcall(vim.api.nvim_del_user_command, "DiffviewClose")
  vim.api.nvim_create_user_command("DiffviewClose", function() M.close() end, {
    desc = "Close Diffview, resolving pending review edits",
  })
  vim.api.nvim_create_user_command("ReviewFinish", M.finish, {
    desc = "Resolve edits from a review whose tab was closed directly",
  })
end

function M.block_index_change()
  local view = current_view()
  local session = view and sessions[view] or nil
  -- A merge review does stage, but on Save, so that writing and staging cannot
  -- come apart -- an unstaged resolution is still an unmerged path to git.
  if session and is_merge(session) then
    return say "Resolve the conflicts and press q -- Save writes and stages them together"
  end
  say "Staging is disabled during a review; save or discard it first, then stage normally"
end

function M.block_restore() say "Use R in the diff pane so the whole-file revert stays pending until the exit prompt" end

function M.block_history_restore()
  say "Restoring a historical file writes immediately, so it is disabled during a review"
end

---@param buf integer
---@return boolean
function M.holds(buf) return protected[buf] ~= nil end

-- Neovim sleeps for a second after printing W10 so the warning can be read, once
-- per buffer and only with a UI attached, which made the first revert or conflict
-- take in every held file look like a hang. The hold is about `:write`, and it is
-- back before this returns; re-arming it does not re-arm the warning.
---@param buf integer
---@param fn fun()
---@param defer? boolean the mutation finishes on a later event-loop turn
function M.mutate(buf, fn, defer)
  if not (protected[buf] and vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].readonly) then return fn() end
  vim.bo[buf].readonly = false

  local function rearm()
    if vim.api.nvim_buf_is_valid(buf) and protected[buf] then vim.bo[buf].readonly = true end
  end
  if defer then vim.schedule(rearm) end

  local ok, err = pcall(fn)
  if not defer then rearm() end
  if not ok then error(err, 0) end
end

function M.setup()
  M.install_commands()
  local group = vim.api.nvim_create_augroup("git_review_write_guard", { clear = true })

  vim.api.nvim_create_autocmd("FileChangedRO", {
    group = group,
    desc = "Say why a review buffer refuses to be written",
    callback = function(args)
      local session = protected[args.buf]
      -- Once per review: every revert in every file trips this, and Neovim's own
      -- W10 is reminder enough from the second time on.
      if not session or session.explained then return end
      session.explained = true
      say "Edits here stay in memory -- press q and choose Save to write them. The W10 warning is that hold"
    end,
  })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    desc = "Account for a review file written past the hold with :w!",
    callback = function(args)
      local session = protected[args.buf]
      local snap = session and session.buffers[args.buf] or nil
      if not snap or writing then return end

      -- `:w!` clears `readonly`, so the hold is put back for the rest of the
      -- review and this file counted as written rather than still pending.
      vim.bo[args.buf].readonly = true
      snap.lines = vim.api.nvim_buf_get_lines(args.buf, 0, -1, true)
      snap.endofline = vim.bo[args.buf].endofline
      snap.modified = false
      snap.disk = disk_state(snap.name)
      snap.tick = vim.b[args.buf].changedtick
      local name = vim.fn.fnamemodify(snap.name, ":~:.")
      if markers(snap) > 0 then
        return say(("%s is written WITH conflict markers still in it"):format(name), vim.log.levels.ERROR)
      end
      say(("%s is written; the rest of the review is still pending"):format(name), vim.log.levels.INFO)
    end,
  })
end

return M
