# Neovim configuration

This is a Neovim-first development environment. Native motions, operators,
text objects, jumplist navigation, buffers, windows, tab pages, quickfix, and
commands remain the editing language. Plugins add project intelligence and
tool integrations; they do not introduce a second editor model.

## Development actions

Frequent Unity actions live under `<Leader>U`, and Rust actions under
`<Leader>R`. `<Leader>ra` is the fallback picker for less frequent operations
valid in the current project, including notebooks, CMake, Cargo manifests, and
Unity maintenance actions. New integrations such as Godot can join that picker
without requiring another universal run/test/debug abstraction.

| Key | Meaning |
| --- | --- |
| `<Leader>ra` | actions valid in the current project |
| `<Leader>Up/Us/Ur` | enter, stop, or restart Unity Play mode |
| `<Leader>Ub/Ut/Ua` | refresh Unity, test at cursor, or attach debugger |
| `<Leader>Ue/Uw/Ul` | Unity errors, warnings, or editor log |
| `<Leader>Rr/Rt/Rd` | run, test, or debug the Rust cursor target |
| `<Leader>Rb` | choose a Cargo build task |
| `<Leader>Re/Rx/Ro` | explain error, expand macro, or open docs.rs |

Use `:ContextStatus` to see what was detected and `:checkhealth user` to check
the assumptions owned by this configuration.

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
`<Leader>Cf` follows a peer, `<Leader>Cp` jumps to a peer cursor, `<Leader>Ci`
shows connection information, `<Leader>Cl` shows daemon output, and
`<Leader>Cs` stops the daemon started by this Neovim. Teamtype protects attached
buffers after a connection closes, so restart Neovim before continuing normal
editing. Closing Neovim also stops that managed daemon; synchronized files
remain on disk.
