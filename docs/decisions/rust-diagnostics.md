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

Rust builds and contextual run actions are separate concerns and live in
`lua/plugins/rust-run.lua`, `lua/overseer/template/user_rust.lua`, and
`lua/user/context/providers/rust.lua`.
