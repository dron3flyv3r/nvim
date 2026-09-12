# Neovim configuration

This is a Neovim-first development environment. Native motions, operators,
text objects, jumplist navigation, buffers, windows, tab pages, quickfix, and
commands remain the editing language. Plugins add project intelligence and
tool integrations; they do not introduce a second editor model.

## Development actions

`<Leader>r` is the contextual entry point for operations valid in the current
project, including run, test, build, notebooks, Cargo dependencies, CMake, and
Unity maintenance. Language-specific engines contribute actions without
claiming their own global key namespace. Native LSP keys remain the direct path
for code intelligence.

| Key | Meaning |
| --- | --- |
| `<Leader>r` | actions valid in the current project |
| `<Leader>R` | repeat the last task |
| `<Leader>n…` | personal project notes (outside the repository) |
| `<Leader>d…` | active debug-session controls and breakpoints |
| `<Leader>ar…` | Claude review and investigation prompts |
| `<Leader>gb/gB/gh` | toggle blame, inspect blame, line history |
| `<Leader>gg/gm` | Neogit status, and its merge popup |
| `gra` | LSP code action, including unresolved Rust dependencies |
| `K` / `gl` | hover documentation / diagnostic details |

In a focused task-output pane, `h` hides the pane while leaving its task
running; `q` stops that task and hides the pane. Reopen retained output from
`<Leader>r` with **Show last task output**.

Use `:ContextStatus` to see what was detected and `:checkhealth user` to check
the assumptions owned by this configuration.

## Reviewing changes

`<Leader>gd` opens the working tree as a two-pane review; `<Leader>gD` compares
against another branch, and `<Leader>gh`/`<Leader>gH` walk history. Each pane
states which side it is -- `BEFORE` against `YOURS` -- and the right pane also
carries your position in the changeset, `file 2/5` and `change 3/8`, so `n` and
`N` can be pressed without losing track. Whole files are shown rather than the
changed lines alone; `zM` collapses to the changes and `zR` opens them again.

A file that exists on only one side is shown in a single pane, labelled `NEW
FILE` or `DELETED`, because there is no other version to compare it against.
Nothing is written until `q`, which asks to save or discard the whole review.
While a review holds a file, `:w` is refused with `E45` and Neovim's `W10`
warning marks the hold; `:w!` writes that one file and reports that the rest of
the review is still pending. A one-line key strip sits along the bottom of the
review, naming the keys for whichever mode you are in; `?` puts it away for the
rest of the session and `F1` still lists everything.

A merge conflict opens the same way and gets three panes: `OURS` on the left,
`THEIRS` on the right, and in the middle the file that will be written, whose
bar counts `conflict 2/3` and turns to `ALL RESOLVED` when the markers are
gone. Both side panes name the branch they come from rather than just a side,
which is what makes a rebase or a cherry-pick readable too. `H` takes the left
version and `L` the right, `B` takes both and `X` drops both, with `gH`, `gL`
and `gB` doing the same to the whole file; `<Leader>cb` takes the common
ancestor, or shows it when git's conflict markers do not carry it. `n` and `N`
walk conflicts here instead of changes, and the revert keys say so rather than
failing, because Vim cannot pick a side with three panes open.

A side can also be taken a line at a time. `<CR>` takes the line the cursor is
on and `<CR>` over a selection takes those lines, from whichever of the three
panes you are reading; the lines are copied into the resolution above the
markers and the conflict is left standing, so takes add up -- two lines from
OURS, then one from THEIRS -- until `X` drops the rest of it. Every resolution
is tagged with what you took, `]r` and `[r` walk them, and a file whose last
conflict is gone stays where it is and says so, with `<Tab>` moving on to the
next file that still has conflicts.

Nothing reaches disk until `q`, which in a merge offers **Save**, **Save and
finish**, and **Discard**. Save writes each resolved file and stages it, since
git counts an unstaged resolution as still unmerged; a file that still has
markers is never written, and the review stays open when one does. Save and
finish is offered only once every conflict is resolved. It then shows what is
staged as an ordinary review, labelled `STAGED`, because until that point
nothing has shown the merge as a change to your own branch -- the panes compare
it to each side. Closing that hands the commit to Neogit, which opens git's own
prepared merge message with the same diff beneath it; `<C-c><C-c>` commits and
`<C-c><C-k>` backs out with the work still staged.

## Personal notes and HTTP requests

`<Leader>nn` creates a personal Markdown note from the current line or selection;
`<Leader>no` and `<Leader>ns` open and search notes for the current project. Notes
are stored under Neovim's data directory, never in the project repository.

Open `.http` or `.rest` files to use HTTP actions from `<Leader>r`. Kulala reads
JetBrains-compatible `http-client.env.json` environment files; keep local secrets
in that file and exclude it through the repository's `.git/info/exclude`.

## Verification

Run `scripts/check.sh` after changing the configuration. It parses every Lua
file, runs formatting and lint checks when their tools are installed, starts
Neovim with temporary cache/state directories, audits local mapping
declarations, exercises focused integration tests, and keeps full-line comments
below 25% of executable Lua.

Set `NVIM_CONFIG_STRICT=1` to require `stylua` and `selene`, as CI should.
Architectural rationale that would otherwise overwhelm source files lives in
[`docs/decisions`](docs/decisions/README.md).

## Layout

- `lua/plugins/` contains Lazy/AstroNvim wiring and user-facing mappings.
- `lua/user/context/` owns the fallback project-action picker and providers.
- `lua/user/workbench/` owns shared execution and output operations.
- `lua/user/languages/` contains language-specific engines.
- `lua/user/integrations/` contains external runtimes such as Unity and Jupyter.
- `lua/user/compat/` contains version/framework compatibility shims only.
- `lua/overseer/template/` contains project and scratch-file task templates.

The configuration intentionally has no permanent IDE-style workbench panel.
Overseer output, DAP UI, quickfix, and pickers appear when needed and then get
out of the way.

## Native behavior

`<Tab>`/`<C-i>`, `?`, normal buffers, and normal tab pages retain their Neovim
meaning. The Danish-layout motion aliases are additive. Press `<F1>` for the
small configuration-specific cheatsheet; built-in help remains the reference
for Neovim itself.

Autosave is deliberately conservative: eligible modified files are written on
`BufLeave` and `FocusLost`, not while typing. Explicit `:write` remains the
normal save-and-format operation.

## Collaboration

`<Leader>C` contains Teamtype's local-first collaboration actions. Every peer
uses a real local project directory and their own editor configuration, so LSP,
Git, project search, tests, debugging, and personal plugins continue to work.

Before connecting, both peers should have a clean checkout at the same commit.
The joining peer's differing files can be overwritten. `.git` stays local by
default; leave `--sync-vcs` disabled for normal pair programming, and let one
person handle commits during a session.

Host:

1. Start Neovim in the project root and press `<Leader>Ch` (or use
   `:TeamtypeHost`).
2. Wait for the join code; it is copied automatically. `<Leader>Cy` or
   `:TeamtypeCopyCode` copies it again.
3. Send the code through a trusted channel.

Guest:

1. Start from the same clean commit, or use an empty directory.
2. Open Neovim in that directory, press `<Leader>Cj`, and paste the join code.

Both peers then open files normally with their own file explorers and pickers.

### Seeing the other peers

Each peer gets their own colour for the session. A resting cursor is a solid
block in that colour, a visual selection is the same hue tinted into the
background so the code stays readable underneath it, and the peer's name plus a
sign-column initial mark the line they are on. Teamtype itself draws every peer
with `TermCursor`, so this is applied by re-stamping the extmarks it creates;
the colours live in `TeamtypePeer<n>Caret`, `Selection`, `Label` and `Sign`,
rebuilt on every `ColorScheme`.

`<Leader>Cw` toggles a peer panel on the right listing everyone, the file and
line they are on, and whether they are selecting. `<CR>` jumps to the peer under
the cursor, `m` mirrors them, and `q` closes the panel.

Mirroring pins a window to one peer: it follows them across files, loading files
you have never opened, and keeps their line centred without taking focus or
moving your own cursor, which is the difference from `<Leader>Cf`.
`<Leader>Cm` mirrors into a floating window at the bottom right. `<Leader>Cc`
instead takes over the window you are standing in, so `<Leader>sv` and then
`<Leader>Cc` in the new split turns that split into a live view of a peer; both
ask which peer when more than one is connected. The borrowed split shows the
peer's name in its winbar and is handed back to the buffer and cursor it had when
you stop. Any number of windows can follow different peers at once, and
`<Leader>CM` stops all of them.

`<Leader>Cf` follows a peer, `<Leader>Cp` jumps to a peer cursor, `<Leader>Ci`
shows connection information, `<Leader>Cl` shows daemon output, and
`<Leader>Cs` stops the daemon started by this Neovim. Teamtype protects attached
buffers after a connection closes, so restart Neovim before continuing normal
editing. Closing Neovim also stops that managed daemon; synchronized files
remain on disk.
