# Autosave boundaries

Autosave always runs on `FocusLost`. Saving on `BufLeave` and shortly after
editing goes idle (`TextChanged`/`InsertLeave`) is opt-in: `save_while_editing`
and `delay` in `M.config` at the top of `lua/user/autosave.lua`, off by
default. It never writes while in insert mode.

It also sweeps before anything that reads the files: `:q`/`:wq`/`:qa` (via
`QuitPre`, so the unsaved-changes check passes), every Overseer task using the
`default` component alias (the `user_autosave` component), `:make`, and DAP
launch/attach. Forced quits -- `:q!`, `:qa!`, `ZQ`, `<C-Q>` -- still discard:
`QuitPre` cannot see a bang, so `CmdlineLeave` and those two mappings tell it.
Each trigger sweeps all eligible modified buffers because LSP workspace edits
can modify background buffers that `:write` on the current buffer would miss.

Passive writes deliberately bypass format-on-save. Explicit `:write` remains
the operation that both saves and formats.

Before writing, the integration compares the file's current size and mtime with
the state recorded when Neovim last read or wrote it. If another process changed
the file, autosave leaves the buffer dirty instead of opening an invisible
confirmation prompt or overwriting the external change. If only the mtime
moved and the content hash still matches, it is not treated as a conflict.

Notebook files are excluded because jupytext and Molten turn a write into a
comparatively expensive code-and-output round trip. Rust users should also know
that an automatic write may trigger rust-analyzer's check-on-save when bacon-ls
is unavailable.

Implementation: `lua/user/autosave.lua` and `lua/plugins/autosave.lua`.
Diagnostics: `:AutosaveStatus`.
