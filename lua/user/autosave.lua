local M = {}

--- Settings. Edit these to change what autosave does. Saving on focus loss,
--- `:q`, and before run/build/debug always happens (unless autosave is off
--- entirely with `<Leader>uW`).
M.config = {
  --- Also save when switching buffers, and shortly after you stop editing
  --- (never mid-insert).
  save_while_editing = false,
  --- How long editing has to be idle before that save, in ms.
  delay = 1000,
}

--- True only while `write()` is inside `:write`. Read by `M.formatting_allowed`
--- to tell an automatic write from one you asked for -- the two go through the
--- same `BufWritePre`, so there is nothing else to tell them apart by.
local writing = false

--- Buffers already warned about a disk conflict, so the warning is one per
--- episode rather than one per second. Cleared by `stamp()`, i.e. as soon as
--- the buffer is read or written and agrees with the disk again.
---@type table<integer, true>
local warned = {}

---@param buf integer
---@return string
local function disk_state(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  return ("%d:%d"):format(vim.fn.getftime(name), vim.fn.getfsize(name))
end

--- Files above this are not hashed; for them a changed mtime alone is a conflict.
local HASH_LIMIT = 2 * 1024 * 1024

---@param buf integer
---@return string?
local function disk_hash(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  local size = vim.fn.getfsize(name)
  if size < 0 or size > HASH_LIMIT then return nil end
  local ok, lines = pcall(vim.fn.readfile, name, "b")
  if not ok then return nil end
  return vim.fn.sha256(table.concat(lines, "\n"))
end

--- Record the current disk state as the agreed one. Wired to the events where
--- Neovim reads or writes the file, in `plugins/autosave.lua`.
---@param buf integer
function M.stamp(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  warned[buf] = nil
  vim.b[buf].autosave_disk = disk_state(buf)
  vim.b[buf].autosave_hash = disk_hash(buf)
end

--- Returns whether the disk disagrees with the stamp, and whether it only
--- looked that way: the mtime moved but the bytes are the ones we last saw (a
--- `touch`, a checkout that restored the same content). `:write` itself still
--- balks at the new mtime then, so the caller has to force it.
---@param buf integer
---@return boolean conflict
---@return boolean touched
local function conflicted(buf)
  local known = vim.b[buf].autosave_disk
  if not known then
    M.stamp(buf)
    return true, false
  end
  if known == disk_state(buf) then return false, false end
  local hash = vim.b[buf].autosave_hash
  if hash and hash == disk_hash(buf) then return false, true end
  return true, false
end

---@param buf? integer Defaults to the current buffer.
---@return boolean
function M.enabled(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if vim.api.nvim_buf_is_valid(buf) and vim.b[buf].autosave == false then return false end
  return vim.g.autosave ~= false
end

---@param buf integer
---@return string?
function M.skip_reason(buf)
  if not (vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf)) then return "not a loaded buffer" end

  local bo = vim.bo[buf]

  -- Nothing to write. Also the common case by a wide margin, so it is first.
  if not bo.modified then return "no unsaved changes" end

  if vim.g.autosave == false then return "autosave is off globally -- `<Leader>uW` turns it back on" end
  if vim.b[buf].autosave == false then return "autosave is off for this buffer (`vim.b.autosave = false`)" end

  -- Anything that is not a plain file-backed buffer: terminals, help, quickfix,
  -- `nofile` scratch, prompt buffers -- and `acwrite`, whose write is somebody
  -- else's autocmd and may do arbitrary work.
  if bo.buftype ~= "" then return ("`buftype` is `%s`, not a plain file"):format(bo.buftype) end

  -- `:enew` and friends. There is no path to write to, and `:write` would
  -- error rather than invent one.
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then return "the buffer has no file name" end

  if not bo.modifiable then return "the buffer is not `modifiable`" end
  if bo.readonly then return "the buffer is `readonly`" end

  -- Notebooks, per the header. Matched on the file name because the buffer's
  -- filetype is `python` by the time jupytext is done with it.
  if name:sub(-6) == ".ipynb" then return "notebooks are excluded on purpose (see the header)" end

  -- Git is blocked on these -- a commit message, a rebase todo -- and writing
  -- one is how you tell git to go ahead. That has to be a deliberate keypress.
  local filetype = bo.filetype
  if filetype == "gitcommit" or filetype == "gitrebase" then
    return "git is waiting on this buffer; writing it is what finishes the operation"
  end

  return nil
end

--- Should this buffer be written automatically?
---@param buf integer
---@return boolean
function M.eligible(buf) return M.skip_reason(buf) == nil end

--- Write one buffer, if it should be.
---@param buf integer
function M.write(buf)
  if not M.eligible(buf) then return end

  -- The prompt guard, per the header. Warn once, then leave the buffer alone
  -- until it and the disk agree again -- `polish.lua`'s `checktime` on
  -- `BufEnter`/`FocusGained` is what usually resolves it.
  local conflict, touched = conflicted(buf)
  if conflict then
    if not warned[buf] then
      warned[buf] = true
      require("astrocore").notify(
        ("Autosave skipped %s -- changed on disk. Save it yourself to choose."):format(
          vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":~:.")
        ),
        vim.log.levels.WARN
      )
    end
    return
  end

  writing = true
  -- `silent` keeps the `"foo.py" 12L, 340B written` line out of the command
  -- line on every passive save. It is not `silent!`: a write that fails
  -- should still say so.
  local ok, err = pcall(vim.api.nvim_buf_call, buf, function() vim.cmd(touched and "silent write!" or "silent write") end)
  writing = false

  if ok then
    M.stamp(buf)
  elseif not warned[buf] then
    warned[buf] = true
    require("astrocore").notify(("Autosave failed: %s"):format(err), vim.log.levels.WARN)
  end
end

--- Write every buffer that qualifies. This is what both boundary triggers call.
function M.sweep()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    M.write(buf)
  end
end

local timer = assert(vim.uv.new_timer())

--- Sweep once editing has been idle for `M.config.delay` ms, when
--- `M.config.save_while_editing` is on. Never fires mid-insert or
--- mid-command: if the timer lands there, it re-arms and waits.
function M.debounce()
  if not M.config.save_while_editing or vim.g.autosave == false then return end
  local delay = M.config.delay
  timer:stop()
  timer:start(
    delay,
    0,
    vim.schedule_wrap(function()
      if vim.api.nvim_get_mode().mode ~= "n" then return M.debounce() end
      M.sweep()
    end)
  )
end

--- Set when the pending quit is one that throws changes away (`:q!`, `ZQ`,
--- `<C-Q>`), so `on_quit` leaves the buffers dirty for it to discard.
local discarding = false

local QUITS = { quit = true, qall = true, quitall = true, close = true, wq = true, wqall = true, xit = true, xall = true, exit = true }

--- `CmdlineLeave`: note whether the command about to run is a forced quit.
--- `QuitPre` cannot see the bang itself.
function M.note_cmdline()
  if vim.fn.getcmdtype() ~= ":" or vim.v.event.abort then return end
  local ok, cmd = pcall(vim.api.nvim_parse_cmd, vim.fn.getcmdline(), {})
  discarding = ok and QUITS[cmd.cmd] == true and cmd.bang == true
end

--- Quit without saving, the way `:q!` does. For mappings that bypass the
--- command line.
---@param cmd string
function M.discard(cmd)
  discarding = true
  vim.cmd(cmd)
  discarding = false
end

--- `QuitPre`: save before `:q`/`:qa`/`:wq` checks for unsaved changes.
function M.on_quit()
  if not discarding then M.sweep() end
  vim.schedule(function() discarding = false end)
end

--- The `format_on_save.filter` installed in `plugins/astrolsp.lua`: format on a
--- write you asked for, never on one this file started. See the header.
---@param _bufnr integer
---@return boolean
function M.formatting_allowed(_bufnr) return not writing end

---@param silent? boolean
function M.toggle(silent)
  vim.g.autosave = not (vim.g.autosave ~= false)
  if vim.g.autosave then M.sweep() end
  if not silent then
    require("astrocore").notify(
      ("Autosave %s"):format(vim.g.autosave and "on" or "off"),
      vim.g.autosave and vim.log.levels.INFO or vim.log.levels.WARN
    )
  end
end

function M.status()
  local buf = vim.api.nvim_get_current_buf()

  local lines = {
    ("Autosave: %s globally, %s in this buffer."):format(
      vim.g.autosave == false and "OFF" or "on",
      M.enabled(buf) and "on" or "OFF"
    ),
  }

  local reason = M.skip_reason(buf)
  lines[#lines + 1] = reason and ("Not writing this buffer: %s."):format(reason)
    or "This buffer has unsaved changes and will be written on the next trigger."

  -- The one skip that is invisible in the options, and the likeliest cause of a
  -- file that quietly stops saving mid-session.
  local known = vim.b[buf].autosave_disk
  if known and known ~= disk_state(buf) then
    lines[#lines + 1] = "The file has also changed on disk -- save it by hand to choose a winner."
  end

  require("astrocore").notify(table.concat(lines, "\n"))
end

return M
