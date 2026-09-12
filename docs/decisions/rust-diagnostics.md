# Rust diagnostics

rustaceanvim owns rust-analyzer; AstroLSP must not start a second client.
rust-analyzer comes from the system package so its proc-macro support stays in
step with the system Rust toolchain. `rust-src` supplies standard-library source
for navigation.

Only one process owns compiler diagnostics:

- When `bacon-ls` is available, it runs Clippy and streams diagnostics.
- Otherwise rust-analyzer uses Clippy through check-on-save.

Running both produces duplicate diagnostics and redundant Cargo work. The
selection is therefore made once while `lua/plugins/rust-lsp.lua` loads.

Whoever owns diagnostics has to be told when the dependency graph changes.
rust-analyzer reloads its own workspace, but bacon-ls pushes diagnostics and
replaces them only after another Cargo run, so an unresolved-import error
survives a `cargo add` that fixed it. `user.languages.rust.project` watches
`Cargo.toml` and `Cargo.lock` mtimes on focus, terminal exit, buffer entry and
write, and asks bacon-ls for an immediate run through the `bacon_ls.run`
command it advertises. `:RustProjectRefresh` and the `<Leader>r` action
**Reload project after a dependency change** do the same on demand, and also
make rust-analyzer re-read the workspace.

Rust builds and contextual run actions are separate concerns and live in
`lua/plugins/rust-run.lua`, `lua/overseer/template/user_rust.lua`, and
`lua/user/context/providers/rust.lua`.
