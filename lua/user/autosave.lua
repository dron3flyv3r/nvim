--- Passive saving at deliberate context boundaries.
---
--- Editing retains Neovim's normal buffer/file distinction: nothing writes on
--- a timer or while insert mode is active. `BufLeave` and `FocusLost` ask this
--- module to save eligible dirty buffers; explicit `:write` remains the normal
--- save-and-format operation.
---
--- ── WHY A SWEEP AND NOT "WRITE THE CURRENT BUFFER" ──────────────────────────
---
--- This is the whole reason the file exists. `<Leader>la` and `<Leader>lr` hand
--- back an LSP workspace edit, and Neovim applies one *in memory*:
--- `vim.lsp.util.apply_text_edits` calls `bufload()` and sets lines, and there
--- is no write anywhere in that path. Measured -- edit `b.txt` from a buffer on
--- `a.txt`:
---
---     bufnr=2  loaded=1  modified=true  buflisted=true
---     disk   b.txt = two          <- unchanged
---     buffer b.txt = CHANGED      <- the edit, in memory only
---
--- So a code action that reaches another file (clangd moving a body into the
--- header, rust-analyzer writing the missing `mod` for `unlinked-file`, any
--- project-wide rename) leaves a modified background buffer that nothing ever
--- writes. `:w` writes the one you are looking at and no more.
---
--- Hence: every trigger writes *every* eligible dirty buffer, not the current
--- one. `BufModifiedSet` would be the obvious precise hook and it does not work
--- -- it does not fire when a non-current buffer is modified through the API
--- (checked on 0.12.2), which is exactly the case that matters here. So the
--- background case is handled by sweeping all buffers at the next deliberate
--- leave/focus boundary.
---
--- ── WHY AUTO-SAVES DO NOT FORMAT ────────────────────────────────────────────
---
--- `plugins/astrolsp.lua` has `format_on_save.enabled = true` for every
--- filetype, so a write is also a `vim.lsp.buf.format`. Left alone, that means
--- ruff/clang-format/stylua running as an unintended side effect of navigating
--- away from a buffer.
---
--- `plugins/autosave.lua` installs `M.formatting_allowed` as the
--- `format_on_save.filter`, so `<Leader>w` and `:w` format exactly as before
--- and the automatic writes do not. Formatting stays something you decide.
---
--- ── THE PROMPT THAT MUST NEVER HAPPEN ───────────────────────────────────────
---
--- `:write` on a buffer whose file changed on disk underneath it does not
--- fail -- it *asks*:
---
---     WARNING: The file has been changed since reading it!!!
---     Do you really want to write to it (y/n)?
---
--- Measured: a headless `:silent write` in that state hangs forever waiting for
--- the answer. For a key you pressed that is a fair question; for a writer that
--- runs a second after you stop typing it is Neovim freezing at random, and the
--- state that provokes it is ordinary -- `git checkout`, `git pull`, a rebase,
--- a formatter run in a terminal. `:write!` would answer it by clobbering the
--- disk copy, which is the wrong answer.
---
--- So the conflict is detected *before* writing and the buffer is skipped, once
--- with a warning. `stamp()` records the file's mtime and size at the moment
--- Neovim reads or writes it, and `conflicted()` compares. It is not Neovim's
--- own internal check -- there is no way to ask for that one without also
--- triggering the prompt -- but it is taken at the same instants, so it says
--- the same thing. A skipped buffer stays dirty and keeps its edits; `<Leader>w`
--- gives you the prompt, deliberately, with a human to answer it.
---
--- ── ONE THING TO WATCH ──────────────────────────────────────────────────────
---
--- A write is a `didSave` to every attached server, and in a Rust project
--- without bacon-ls that means `checkOnSave` -- a `cargo clippy` shell-out --
--- per passive save rather than per `:w`. It cannot block your own builds, because
--- `plugins/rust-lsp.lua` already gives the server its own target directory,
--- but it is real CPU whenever a passive boundary saves. `<Leader>uW` turns autosave off
--- globally, and `:lua vim.b.autosave = false` for one buffer.
---
--- ── WHAT IS DELIBERATELY NOT SAVED ──────────────────────────────────────────
---
--- `.ipynb` -- writing one runs jupytext *and* `MoltenExportOutput!`, a Python
--- remote call costing a few hundred milliseconds. The notebook integration calls
--- that out as the reason this config had no autosave at all; it is excluded
--- rather than being a reason not to have one. See `skip_reason()` for the rest,
--- and `:AutosaveStatus` for which of them applies to the buffer you are in.

local M = {}

--- True only while `write()` is inside `:write`. Read by `M.formatting_allowed`
--- to tell an automatic write from one you asked for -- the two go through the
--- same `BufWritePre`, so there is nothing else to tell them apart by.
local writing = false

--- Buffers already warned about a disk conflict, so the warning is one per
--- episode rather than one per second. Cleared by `stamp()`, i.e. as soon as
--- the buffer is read or written and agrees with the disk again.
---@type table<integer, true>
local warned = {}

--- What the file behind `buf` looked like last time Neovim and it agreed.
---
--- mtime and size, which is the same pair Neovim's own check uses. Second
--- granularity, so a change made within the same second as the read is
--- invisible to both -- and Neovim will then ask its question, which is why
--- `write()` still guards the call.
---@param buf integer
---@return string
local function disk_state(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  return ("%d:%d"):format(vim.fn.getftime(name), vim.fn.getfsize(name))
end

--- Record the current disk state as the agreed one. Wired to the events where
--- Neovim reads or writes the file, in `plugins/autosave.lua`.
---@param buf integer
function M.stamp(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  warned[buf] = nil
  vim.b[buf].autosave_disk = disk_state(buf)
end

--- Has the file moved under the buffer since then?
---
--- An unstamped buffer counts as conflicted exactly once: it is stamped and
--- skipped, and written on the next sweep a second later. This only happens to
--- a buffer read before these autocmds existed -- a file named on the command
--- line, in the worst case -- and one skipped write is a better trade than
--- assuming agreement that was never checked.
---@param buf integer
---@return boolean
local function conflicted(buf)
  local known = vim.b[buf].autosave_disk
  if not known then
    M.stamp(buf)
    return true
  end
  return known ~= disk_state(buf)
end

--- Is autosave switched on for this buffer?
---
--- `vim.g.autosave` / `vim.b.autosave` are the toggle, and they follow
--- AstroLSP's `autoformat` convention: unset means on, buffer wins over global.
--- `<Leader>uW` flips the global one, and `plugins/autosave.lua` seeds it to
--- `true` at startup so that press always reads as "it was on, now off" rather
--- than flipping a value nothing had ever shown you.
---@param buf? integer Defaults to the current buffer.
---@return boolean
function M.enabled(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if vim.api.nvim_buf_is_valid(buf) and vim.b[buf].autosave == false then return false end
  return vim.g.autosave ~= false
end

--- Why this buffer will NOT be written automatically, or `nil` if it will.
---
--- Everything here is a case where an automatic `:write` is either impossible
--- or actively unwanted; a buffer that fails is left dirty for you to deal with
--- by hand, never force-written.
---
--- The reasons are strings rather than a bare `false` because every one of
--- these skips is silent by design, so "it is not saving and I cannot see why"
--- is the only way this feature fails. `:AutosaveStatus` answers that with them.
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
  if conflicted(buf) then
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
  local ok, err = pcall(vim.api.nvim_buf_call, buf, function() vim.cmd "silent write" end)
  writing = false

  if ok then
    -- Stamp here rather than leaving it to the `BufWritePost` autocmd.
    --
    -- MEASURED, and the cause of a bug where every autosave warned about a
    -- disk conflict that had not happened: a `:write` run from inside an
    -- autocmd callback fires NO autocmds of its own unless the outer one is
    -- `nested` (`:h autocmd-nested`).
    --
    --     BufWritePost fired: 0
    --     stamp: 1788176960:6   actual on disk: 1788176964:6
    --
    -- The leave/focus triggers are `nested`, which gets
    -- `didSave` and the other `BufWritePost` consumers back. This line makes
    -- the bookkeeping true regardless: `write()` knows it wrote, and should
    -- not need an event to find out.
    M.stamp(buf)
  elseif not warned[buf] then
    -- `nvim_buf_call` re-raises with its own prefix, and the interesting half
    -- is the Vim error at the end of it. Once per episode, like the conflict
    -- above: a read-only directory would otherwise report itself on every
    -- keystroke.
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

--- The `format_on_save.filter` installed in `plugins/astrolsp.lua`: format on a
--- write you asked for, never on one this file started. See the header.
---@param _bufnr integer
---@return boolean
function M.formatting_allowed(_bufnr) return not writing end

--- `<Leader>uW`. Mirrors `astrocore.toggles`: flip, then say what it is now.
---
--- Autosave is ON by default, so the FIRST press turns it off -- which is the
--- press it is easiest to make while believing it does the opposite. Hence the
--- WARN level on that half: turning the feature off is the direction worth
--- noticing, and a blue "Autosave off" scrolling past is how you end up
--- convinced autosave is broken. `:AutosaveStatus` answers it after the fact.
---@param silent? boolean
function M.toggle(silent)
  -- Deliberately the global and not `M.enabled()`, which also consults
  -- `vim.b.autosave`: this key owns `vim.g` only, and a buffer opted out by
  -- hand should not decide which way the global flips.
  -- `~= false` rather than `not`, because unset still has to mean on.
  vim.g.autosave = not (vim.g.autosave ~= false)
  if vim.g.autosave then M.sweep() end
  if not silent then
    require("astrocore").notify(
      ("Autosave %s"):format(vim.g.autosave and "on" or "off"),
      vim.g.autosave and vim.log.levels.INFO or vim.log.levels.WARN
    )
  end
end

--- `:AutosaveStatus`. Whether this buffer is being written, and if not, why.
---
--- Every refusal in `skip_reason` and the disk-conflict guard is silent by
--- design -- one warning per episode at most -- so there is otherwise nothing
--- to look at when a file is not saving, and `vim.g.autosave` on its own does
--- not tell you about the buffer in front of you.
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
