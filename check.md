# Unity work-PC verification

Use this checklist on the large work project before depending on the setup for daily work. Start from a clean Git working tree so Unity-generated project files and Neovim edits are easy to distinguish.

## Before opening the project

- [ ] Record `git status --short`.
- [ ] Record the current number and memory use of Roslyn, MSBuild, and dotnet processes:

  ```sh
  ps -eo pid,ppid,%cpu,rss,etime,cmd | rg 'roslyn|MSBuild|dotnet'
  ```

- [ ] Confirm whether generated `.sln`, `.csproj`, and `.vscode` files are ignored or committed by the company repository.

## Unity integration

- [ ] Open a C# file below the Unity project root (`Assets/` beside `ProjectSettings/ProjectVersion.txt`).
- [ ] Run `:UnityStatus` and record anything shown as unavailable.
- [ ] Press `<Leader>r` and confirm the Unity actions appear.
- [ ] Test Play with `<Leader>rr`.
- [ ] Test Stop with `<Leader>rk`.
- [ ] Select **Restart Play mode** from `<Leader>r`.
- [ ] After using Unity Play, confirm `<Leader>rl` repeats it as a restart.
- [ ] Test Refresh/recompile with `<Leader>rb`.
- [ ] Test Pause and Resume from `<Leader>r`.
- [ ] Test the EditMode test under the cursor with `<Leader>rt`.
- [ ] Select both an EditMode and PlayMode test from `<Leader>r`.
- [ ] Follow the Unity editor log with `<Leader>ro`.
- [ ] Load compiler errors and warnings from `<Leader>r`.

## Roslyn and editing

- [ ] Run `:LspInfo` in a C# buffer. There should be exactly one C# language server: `roslyn_ls`.
- [ ] Record the time from opening the first C# file until the notification `Roslyn project initialization complete`.
- [ ] Confirm completion for Unity types such as `Vector3` and that accepting an unimported type can add its namespace.
- [ ] Test hover, go-to-definition, references, rename, and `<Leader>la` code actions.
- [ ] Open files from several representative assembly definitions and packages.
- [ ] Confirm diagnostics change while editing an open file, before writing it.
- [ ] Save and refresh Unity, then confirm Unity-only compiler failures appear through the contextual Problems action.

Roslyn is configured to analyze open files rather than the complete solution in the background. This reduces steady-state CPU and memory on large Unity solutions. It also means an unopened file might not have Roslyn diagnostics until it is opened. Unity's own compilation remains the project-wide source of truth.

## Diagnostics: when they update

There are two separate diagnostic sources:

1. **Roslyn diagnostics** are sent through the LSP for open C# buffers. Neovim is configured to display updates during Insert mode, so they can appear while typing; a disk write is not inherently required. Some analyzers may still wait for Roslyn to finish a pass or for a save.
2. **Unity compiler diagnostics** come from Unity's latest compilation in `Editor.log`. Unity can only compile the version written to disk. Save the buffer, then let Unity refresh or press `<Leader>rb`. The Problems actions parse errors, or errors plus warnings, from the latest compile. They do not convert ordinary Unity log messages into Neovim diagnostics; `<Leader>ro` follows the raw log, including ordinary `Debug.Log` and editor output.

The normal Neovim diagnostic display supports Error, Warning, Information, and Hint severities when an LSP publishes them. Use `]d` / `[d` (or the Danish equivalents shown in the cheatsheet) to move between visible diagnostics. The Unity compiler-log parser specifically imports only compiler errors and optionally compiler warnings.

## Autosave and LSP workspace edits

Autosave is on by default and runs only at deliberate boundaries:

- `BufLeave`: leaving one editing buffer for another buffer.
- `FocusLost`: moving focus away from Neovim to Unity, a browser, or another application.

At either boundary, it sweeps **all loaded modified file buffers**, not only the current buffer. This is intentional: `<Leader>la`, rename, and other LSP actions can edit multiple buffers in memory, including files that are not currently visible.

- [ ] In a clean test file, use `<Leader>la` to change a member's visibility.
- [ ] Immediately check `:set modified?`; `modified` means the edit is still only in the Neovim buffer.
- [ ] Move to another real editing buffer or move application focus away from Neovim.
- [ ] Return and check `:set modified?` again. It should report `nomodified`.
- [ ] Verify the change on disk with Git diff.
- [ ] Test a rename or code action that modifies more than one file and verify that every affected file is written on the next boundary.

If it does not save, run `:AutosaveStatus`. It reports whether autosave is disabled or whether the current buffer is excluded. Also check:

- `<Leader>uW` toggles autosave globally; because autosave starts enabled, the first press turns it **off**.
- Unnamed, read-only, special, and notebook buffers are deliberately excluded.
- If the file changed externally, autosave refuses to overwrite it and leaves the buffer modified for a manual decision.
- Passive autosaves deliberately do **not** format. Explicit `<Leader>w` or `:write` still performs the configured format-on-save behavior.
- A terminal multiplexer or terminal emulator that does not forward focus events may prevent `FocusLost`; `BufLeave` and explicit writes still work.

## Debugger

- [ ] Start Unity and attach with `<Leader>rd` or `:UnityAttach`.
- [ ] Set a breakpoint using the normal DAP mapping.
- [ ] Enter Play mode and confirm the breakpoint is hit.
- [ ] Test continue, step over, step into, and debugger termination.
- [ ] Reattach after a Unity domain reload.

## Performance observations

- [ ] Record idle CPU and memory after Roslyn initialization settles.
- [ ] Record responsiveness while completion, references, rename, and diagnostics are active.
- [ ] Open approximately ten representative C# files and record whether CPU settles afterward.
- [ ] Check the size of Unity's `Editor.log`; loading compiler errors scans the complete log on demand and may be slow when the log is extremely large.
- [ ] Close Neovim, wait briefly, and run the process command again. Look for accumulating orphaned MSBuild/dotnet workers.
- [ ] Compare `git status --short` with the initial result, especially after configuring or running `:UnityShim`.

## Results

Record the project size, Unity version, cold Roslyn initialization time, steady-state memory/CPU, any missing actions, unexpected repository changes, and anything that felt slow enough to interrupt normal work.
