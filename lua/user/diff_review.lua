--- Transactional editing for Diffview working-tree reviews.
---
--- Diffview normally edits the real file buffer. That is pleasantly Vim-like,
--- but it also means a `:write` (or this config's BufLeave autosave) makes a
--- revert permanent immediately. This module puts a small transaction around
--- those buffers: their contents remain ordinary editable Neovim buffers, but
--- autosave is suppressed until the review is explicitly saved or discarded.

local M = {}

---@class DiffReviewSnapshot
---@field buf integer
---@field name string
---@field lines string[]
---@field modified boolean
---@field endofline boolean
---@field autosave boolean?
---@field autoformat boolean?
---@field disk string
---@field tick integer

---@class DiffReviewSession
---@field view table
---@field buffers table<integer, DiffReviewSnapshot>
---@field finishing boolean

---@type table<table, DiffReviewSession>
local sessions = setmetatable({}, { __mode = "k" })

---@type DiffReviewSession[]
local orphans = {}

---@type table<integer, DiffReviewSession>
local protected = {}

---True only around the writes approved by the Save choice. A BufWritePre guard
---below rejects muscle-memory `:w`, `ZZ`, `<Leader>w`, and plugin writes while
---the transaction is pending. `:noautocmd write` remains Neovim's intentional
---expert escape hatch, much like `qall!` is for modified buffers.
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
      disk = disk_state(vim.api.nvim_buf_get_name(buf)),
      tick = vim.b[buf].changedtick,
    }
  end

  -- This is buffer-local, so BufLeave, FocusLost and edits made through an LSP
  -- cannot leak a pending review to disk. `finish_session` restores the exact
  -- previous value, including nil (inherit the global default).
  vim.b[buf].autosave = false
  vim.b[buf].autoformat = false
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

---@param session DiffReviewSession
local function restore_autosave(session)
  for _, snap in pairs(session.buffers) do
    if protected[snap.buf] == session then
      if vim.api.nvim_buf_is_valid(snap.buf) then
        vim.b[snap.buf].autosave = snap.autosave
        vim.b[snap.buf].autoformat = snap.autoformat
      end
      protected[snap.buf] = nil
    end
  end
end

---@param session DiffReviewSession
local function forget(session)
  restore_autosave(session)
  sessions[session.view] = nil
  for i = #orphans, 1, -1 do
    if orphans[i] == session then table.remove(orphans, i) end
  end
end

---@param session DiffReviewSession
---@return boolean
local function save(session)
  local changed = pending(session)

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
    local ok, err = pcall(vim.api.nvim_buf_call, snap.buf, function() vim.cmd "silent write" end)
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

  notify(("Saved review changes in %d file%s"):format(#changed, #changed == 1 and "" or "s"), vim.log.levels.INFO)
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
---@return boolean finished
local function prompt(session, allow_cancel)
  local count = #pending(session)
  if count == 0 then
    forget(session)
    return true
  end

  local buttons = allow_cancel and "&Save\n&Discard\n&Cancel" or "&Save\n&Discard\n&Keep pending"
  local choice = vim.fn.confirm(
    ("Diff review has pending changes in %d file%s.\nNothing has been written yet."):format(
      count,
      count == 1 and "" or "s"
    ),
    buttons,
    3,
    "Question"
  )

  if choice == 1 then
    if not save(session) then return false end
  elseif choice == 2 then
    discard(session)
  else
    return false
  end

  forget(session)
  return true
end

local function raw_close() require("diffview").close() end

---The only normal exit from a working-tree review. File-history views have no
---editable local side and therefore close without a transaction prompt.
function M.close()
  local view = current_view()
  local session = view and sessions[view] or nil
  if session and not prompt(session, true) then return end
  raw_close()
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
  notify "Staging is disabled during a safe review; save or discard it first, then stage normally"
end

function M.block_restore() notify "Use R in the diff pane so the whole-file revert stays pending until the exit prompt" end

function M.block_history_restore()
  notify "Restoring a historical file writes immediately, so it is disabled in safe review mode"
end

local write_guard = vim.api.nvim_create_augroup("diff_review_write_guard", { clear = true })
vim.api.nvim_create_autocmd("BufWritePre", {
  group = write_guard,
  desc = "Hold Diffview review edits until its Save/Discard prompt",
  callback = function(args)
    if not protected[args.buf] or writing then return end
    notify("Write held in memory -- press q and choose Save to finish the review", vim.log.levels.ERROR)
    error "Diff review write blocked until Save"
  end,
})

return M
