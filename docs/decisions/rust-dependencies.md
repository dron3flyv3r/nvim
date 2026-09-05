# Rust dependency actions

The contextual `<Leader>r` picker includes **Search and add a crate**. It
searches crates.io, previews the selected crate's current metadata and features,
and opens its full documentation with `<C-o>`. After choosing the dependency
kind and optional features, it shows the exact `cargo add` command and target
manifest before making changes.

The same picker includes **Browse dependency features**. Existing features are
marked with `✓`; selected new features are added with `cargo add`. Default
features can be enabled or disabled explicitly. Removing an individual feature
remains a normal `Cargo.toml` edit because Cargo has no corresponding safe
command-line operation. The explicit `:RustDependencySearch` and
`:RustDependencyFeatures` commands are also available.

Native `gra` recognizes rustc `E0432` and `E0433` diagnostics at the cursor. It
offers the same dependency flow for the unresolved top-level crate, while
retaining an option to show the ordinary LSP code actions. `<Leader>xa` remains
an alias, and `<Leader>la` provides a diff-preview presentation.

Search and metadata come from `cargo search` and `cargo info`. Cargo therefore
owns registry configuration and version selection; the editor does not keep a
hard-coded crate catalogue. All registry access is on demand.
