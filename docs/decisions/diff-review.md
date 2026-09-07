# Diff review and merge conflicts

Rationale and measured behaviour behind `lua/user/diff_hud.lua`,
`lua/user/diff_review.lua`, `lua/user/diff_keys.lua` and the Diffview spec in
`lua/plugins/git.lua`.

## A `BufWritePre` error is not a write barrier

The review's first attempt at holding a file back threw from a `BufWritePre`
callback. That only aborts writes issued through the API -- `vim.cmd "write"`,
autosave, a formatter, an LSP edit -- because Vim honours the abort only when
there is a try-level on the stack. A `:w` typed on the command line printed the
error and wrote the file anyway:

```
typed :w      -> "Error in BufWritePre…" + file written
vim.cmd "w"   -> aborted, disk untouched
```

`'readonly'` is what actually holds: `:write` refuses a readonly buffer itself,
before any autocommand, so both paths stop with `E45`. The costs of that choice,
all handled in `diff_review.lua`:

- Neovim prints `W10: Warning: Changing a readonly file` on the first change to
  each held buffer. A `FileChangedRO` handler explains it once per review.
- `:w!` clears `readonly` and writes. That is honoured rather than half-blocked:
  a `BufWritePost` accountant re-arms the hold, re-baselines the snapshot so `q`
  no longer counts the file as pending, and says the rest of the review is still
  waiting. If the file still has conflict markers, it says that instead.
- Anything asking "was this file writable?" must ask the snapshot, not the live
  option, which is why `M.writable` exists. The revert keys once checked
  `vim.bo.readonly` directly and refused every file in a held review.

## Diff highlighting outranks everything else on a line

An earlier plan was to mirror the cursor line into the other pane, because
Diffview already keeps the panes aligned (`cursorbind`, verified: a cursor on
line 41 of the working file sits on line 44 of the old one, on the same screen
row) but nothing marks the counterpart line. Measuring the resolved highlight of
a cell showed why the obvious approaches cannot work: on a **changed** line,
`DiffChange`'s background beat `CursorLine`, an extmark `line_hl_group`, and a
char-range `hl_group` at priority 300. Only the sign column, the line-number
highlight and virtual text survive there. `CursorLine`'s background is also
identical to `Normal`'s in this colourscheme, so the mirror is invisible even on
unchanged lines. The idea was dropped rather than half-built.

## Git's conflict markers usually have no base section

`merge.conflictStyle` defaults to `merge`, which writes `<<<<<<<`, `=======` and
`>>>>>>>` but no `|||||||` section, so Diffview's `conflict_choose("base")`
resolves to nothing. Rather than change a global git setting on the user's
behalf, `<Leader>cb` takes the base from the markers when they carry it and
otherwise reads stage 1 (`git show :1:<path>`) into a read-only float to copy
from. A float, not a split: a new window inside the layout is a window Diffview
tries to fold into the diff.

## Where the merge keys are bound

Diffview attaches `keymaps.diff3` and `keymaps.diff4` only in its merge layouts,
and layout keymaps override `keymaps.view` for the same key
(`config.extend_keymaps(conf.keymaps.view, state.keymaps)` in `vcs/file.lua`).
That is why `H`, `L`, `B` and `X` are bound there rather than guarded at
runtime: they cannot shadow anything in an ordinary two-pane diff, and `n` can
mean conflicts in a merge and changes everywhere else without a mode check.

Keys the review needs from the **file panel** are a separate matter: Diffview
opens with the cursor there, and an unbound `n` falls through to Vim's own
search -- which reports `E35` or jumps to an unrelated match from the shada
file. `n` and `N` in `keymaps.file_panel` move into the diff first.

## Taking part of a side

`conflict_choose` replaces a whole marker region with one side's content, which
is all Diffview offers. Taking lines works the other way round: the selected
lines are copied in **above** `<<<<<<<` and the region is left standing, so
several takes accumulate and `X` -- already "drop both sides" -- ends the
region by deleting what is left of it. Three consequences worth knowing:

- The conflict counter cannot lie during a partial take. A region with markers
  still in it counts as unresolved however much has been taken out of it, which
  is also why nothing auto-advances mid-build.
- Lines are taken as **text** from whichever buffer is focused, so the side
  panes work without mapping their line numbers onto the file being written.
  Diffview keeps the panes aligned, but not numbered alike.
- Marker lines are filtered by line number (`region.ours.first` and friends),
  not by looking like markers: a row of `=======` is a heading in Markdown and
  a conflict separator only inside a region.

`gH`, `gL` and `gB` deliberately leave no resolution marks. `conflict_choose_all`
is asynchronous and resolves every region at once, so the positions to mark are
gone by the time it returns -- and a whole-file take is one decision, which the
counter already reports.

## Resolution marks are virtual text, not signs

A resolved region has no markers left, so without something added there is
nothing to navigate back to and nothing to check. The marks are extmarks
carrying `virt_text` at end of line plus `number_hl_group`, for two measured
reasons: a diff background outranks any extmark highlight on the line (see
above), and the sign column already carries Git's own signs, which would win or
lose against ours by priority. Extmarks also move with later edits, so a mark
keeps pointing at its resolution while the file is still being worked on.

## Why a resolved file stops instead of advancing

Auto-advance originally jumped to the next conflicted file the moment a file's
last conflict went away, which is the one moment the resolutions are on screen
to be read. It now sets the count of files left, says so in the RESULT bar, and
waits for `<Tab>`. `<Tab>` walks forward with wrapping and only then falls back
to Diffview's own next-entry, since the next file needing work can be one
already walked past.

Counting those files reads the ones the review has not opened, so it is done
when a file is opened or finished and cached in a buffer variable -- never from
the winbar, which is evaluated on every redraw. For the same reason the count
looks for a loaded buffer **by name** first: a file resolved earlier is still
loaded but its layout has moved on, and the copy on disk still has the markers.

## Why the finish shows the staged diff

The merge panes compare the resolution to each side, so nothing in the review
shows the merge as a change to your own branch. "Save and finish" therefore
stages, reopens the staged changes as an ordinary review (`DiffviewOpen
--cached`, labelled `STAGED`), and hands the commit to Neogit only when that
closes. It is scheduled rather than called inline because Diffview keeps one
view per tab and the prompt runs while the merge view is still open. Neogit's
commit editor then shows the same diff under the message, which is the escape
hatch: `<C-c><C-k>` abandons the commit with the resolutions still staged.

## Why staging happens on Save

Git treats a resolved-but-unstaged file as still unmerged, so a merge review
that wrote a file has not finished with it. Save therefore writes and stages
together, and "Save and finish" is offered only when nothing is unresolved --
including conflicted files the review never opened, since `git merge --continue`
counts those too. Everything else about staging stays blocked during a review,
because an index change cannot participate in an in-memory transaction.

## Test harness notes

The conflict work was verified against scratch repositories driven through a
pty (`script -qc "nvim …"`), because several behaviours only appear with real
typed input and a real terminal:

- `vim.fn.confirm` does not read fed keystrokes, so the `q` prompt is verified
  by stubbing `vim.fn.confirm` and asserting on its message and button list.
- Notifications go through `vim.notify`, never `:messages`, so a probe has to
  wrap `vim.notify` to see them.
- Always pass `-i NONE`. Without it a probe inherits the real shada file, and a
  stray `n` repeats a search from another project.
- A hit-enter prompt blocks every `vim.defer_fn` in the queue, which looks
  exactly like a hang. Raise `cmdheight` in probes and capture the pty log to
  see the prompt.
