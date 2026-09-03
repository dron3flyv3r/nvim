# Autosave boundaries

Autosave runs on `BufLeave` and `FocusLost`; it does not write while typing.
Each trigger sweeps all eligible modified buffers because LSP workspace edits
can modify background buffers that `:write` on the current buffer would miss.

Passive writes deliberately bypass format-on-save. Explicit `:write` remains
the operation that both saves and formats.

Before writing, the integration compares the file's current size and mtime with
the state recorded when Neovim last read or wrote it. If another process changed
the file, autosave leaves the buffer dirty instead of opening an invisible
confirmation prompt or overwriting the external change.

Notebook files are excluded because jupytext and Molten turn a write into a
comparatively expensive code-and-output round trip. Rust users should also know
that an automatic write may trigger rust-analyzer's check-on-save when bacon-ls
is unavailable.

Implementation: `lua/user/autosave.lua` and `lua/plugins/autosave.lua`.
Diagnostics: `:AutosaveStatus`.
