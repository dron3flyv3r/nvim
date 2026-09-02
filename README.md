# Neovim configuration

This is a Neovim-first development environment. Native motions, operators,
text objects, jumplist navigation, buffers, windows, tab pages, quickfix, and
commands remain the editing language. Plugins add project intelligence and
tool integrations; they do not introduce a second editor model.

## Contextual development actions

`<Leader>r` is the single project-action namespace. The same small vocabulary
works in every language and project:

| Key | Meaning |
| --- | --- |
| `<Leader>ra` | all actions valid at the cursor |
| `<Leader>rr` | run the most specific current target |
| `<Leader>rl` | repeat the last contextual run |
| `<Leader>rt` | test the most specific current target |
| `<Leader>rd` | debug the most specific current target |
| `<Leader>rb` | build or refresh the current project |
| `<Leader>ro` | show the most relevant output |
| `<Leader>rk` | stop the most relevant running process |

Cursor context wins. For example, `<Leader>rr` runs a notebook cell when the
cursor is in a cell-based Python buffer, a Rust runnable in Rust, Unity Play in
a Unity project, a CMake target in CMake C/C++, and otherwise opens the project
task picker. Specialist operations stay discoverable in `<Leader>ra` instead
of occupying separate language-specific prefixes.

Use `:ContextStatus` to see what was detected and `:checkhealth user` to check
the assumptions owned by this configuration.

## Layout

- `lua/plugins/` contains Lazy/AstroNvim wiring and user-facing mappings.
- `lua/user/context/` owns context detection, action selection, and providers.
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
default; do not add Teamtype's experimental `--sync-vcs` option for normal pair
programming, and let one person handle commits during a session.

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
`<Leader>Cf` follows a peer, `<Leader>Cp` jumps to a peer cursor, `<Leader>Ci`
shows connection information, `<Leader>Cl` shows daemon output, and
`<Leader>Cs` stops the daemon started by this Neovim. Teamtype protects attached
buffers after a connection closes, so restart Neovim before continuing normal
editing. Closing Neovim also stops that managed daemon; synchronized files
remain on disk.
