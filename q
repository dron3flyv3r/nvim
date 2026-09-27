[1mdiff --git a/README.md b/README.md[m
[1mindex a0cb292..1b0f82e 100644[m
[1m--- a/README.md[m
[1m+++ b/README.md[m
[36m@@ -8,7 +8,7 @@[m [mtool integrations; they do not introduce a second editor model.[m
 ## Development actions[m
 [m
 `<Leader>r` is the contextual entry point for operations valid in the current[m
[31m-project, including run, test, build, notebooks, Cargo dependencies, CMake, and[m
[32m+[m[32mproject, including run, test, build, notebooks, Cargo dependencies, CMake, Make, and[m
 Unity maintenance. Language-specific engines contribute actions without[m
 claiming their own global key namespace. Native LSP keys remain the direct path[m
 for code intelligence.[m
[1mdiff --git a/experimental/AGENTS.md b/experimental/AGENTS.md[m
[1mindex c12dd8c..92b98ce 100644[m
[1m--- a/experimental/AGENTS.md[m
[1m+++ b/experimental/AGENTS.md[m
[36m@@ -44,7 +44,7 @@[m [mlua/[m
   core/               the configuration itself, no plugins involved[m
     options.lua       vim.o / vim.opt[m
     diagnostics.lua   vim.diagnostic.config and the inline-scope toggle[m
[31m-    autosave.lua      registered filetypes, idle timers and suspensions[m
[32m+[m[32m    autosave.lua      writes on leave, focus loss and quit, and suspensions[m
     codelens.lua      the global code lens state and its suspensions[m
     colorscheme.lua   the remembered colourscheme and its fallback[m
     keymaps.lua       keymaps that do not belong to a plugin[m
[36m@@ -363,6 +363,24 @@[m [mThe last one explains what was detected and why any unavailable action is[m
 unavailable, and is the first thing to reach for when `<Leader>r` is emptier[m
 than expected.[m
 [m
[32m+[m[32m## Autosave[m
[32m+[m
[32m+[m[32m`core/autosave.lua` writes every modified file buffer — hidden ones included,[m
[32m+[m[32mwhich is what catches a rename or a code action that edited a file you never[m
[32m+[m[32mlooked at — on `BufLeave`, `FocusLost` and quit. It never writes on an idle[m
[32m+[m[32mtimer: an idle write per pause was what made it save constantly. It applies to[m
[32m+[m[32mevery file; there is no per-language registration. It skips buffers that are[m
[32m+[m[32mreadonly, in a diff, suspended, named by a URI or under `.git/`, the last so[m
[32m+[m[32ma Neogit commit message is never written behind your back.[m
[32m+[m
[32m+[m[32mQuitting borrows `'autowriteall'` for the length of the one command, from[m
[32m+[m[32m`QuitPre`. That is what keeps `:q!` meaning discard, which a flush from[m
[32m+[m[32m`QuitPre` cannot tell apart from `:q`. It is not left on, because it also[m
[32m+[m[32mwrites on `:!` and `<C-^>` and those writes would reach the Rust watcher as[m
[32m+[m[32man explicit `:w`. When any modified buffer is one autosave would skip, the quit[m
[32m+[m[32mfalls back to the ordinary `confirm` dialog. Every write it makes answers[m
[32m+[m[32m`core.autosave.writing()`.[m
[32m+[m
 ## Execution[m
 [m
 `core.task` runs every external process whose **output you watch** — a build, a[m
[36m@@ -668,7 +686,7 @@[m [mhandled in `review.lua`:[m
   option, which is why `M.writable` exists. The revert keys once read[m
   `vim.bo.readonly` directly and refused every file in a held review.[m
 [m
[31m-The snapshot does not carry `autosave` or `autoformat`. The Rust idle autosave[m
[32m+[m[32mThe snapshot does not carry `autosave` or `autoformat`. Autosave[m
 is suspended through `core.autosave` while a buffer is held and resumed when the[m
 review releases it; any future automatic writer needs the same explicit hook or[m
 a held file can reach disk behind the review's back. An agent is the same hazard[m
[36m@@ -1208,7 +1226,7 @@[m [mIt is `vim.ui.select` rather than a picker of its own, which snacks owns, so[m
 ## Keys[m
 [m
 Prefixes in use: `<Leader>a` assistants, `<Leader>f` find, `<Leader>s` search, `<Leader>u` toggles,[m
[31m-`<Leader>w` windows, `<Leader>b` buffers, `<Leader>r`/`<Leader>R` actions,[m
[32m+[m[32m`<Leader>w` write, `<Leader>b` buffers, `<Leader>r`/`<Leader>R` actions,[m
 `<Leader>d` the debugger, `<Leader>t` the terminal, `<Leader>q` the macro list.[m
 `<Leader>m`/`<Leader>M` and[m
 `<Leader>1`–`<Leader>4`[m
[36m@@ -1269,6 +1287,12 @@[m [mmapping once:[m
   rebound to cancel in insert mode too: snacks' default cancels from normal mode[m
   only, so a prompt-focused menu would otherwise take two presses to dismiss[m
   where every other list here takes one.[m
[32m+[m[32m- `jj` `jk` `kj` `kk` typed within 200 ms leave insert mode. The first key is[m
[32m+[m[32m  inserted at once and removed by the second, instead of an `inoremap jj`[m
[32m+[m[32m  holding every `j` back for `timeoutlen`. The window replaces AstroNvim's[m
[32m+[m[32m  better-escape plugin; it is ten lines in `core/keymaps.lua`.[m
[32m+[m[32m- Window splits have no leader keys: `<C-w>v/s/c/o` are the native spelling[m
[32m+[m[32m  and need no AltGr. `<Leader>w` is write, and detach's keys are `<Leader>W`.[m
 - Insert-mode `<CR>` and `<BS>` belong to mini.pairs, which takes them only if[m
   nothing else has. Binding either one means reproducing `MiniPairs.cr()` and[m
   `MiniPairs.bs()` inside the new mapping.[m
[36m@@ -1327,10 +1351,10 @@[m [mcloses them all, and there is no layout persistence — the main is the session.[m
 of the Neovim layout, and do nothing when there is none — never an unrelated[m
 window. A new side starts through the fish `fullscreen` function when it exists.[m
 Hyprland 0.56's Lua config reads `hyprctl dispatch` as a Lua expression, so the[m
[31m-plugin tries `hl.dsp.focus{…}` first and the classic syntax second; `<Leader>wd` detaches the buffer into a new side, `<Leader>wn` opens an[m
[31m-empty one, `<Leader>wH/J/K/L` send the buffer to the linked instance in that[m
[31m-direction by window geometry, `<Leader>wa` sends it back to the main and[m
[31m-`<Leader>wi` lists the group. A buffer is wiped before it is sent, so the[m
[32m+[m[32mplugin tries `hl.dsp.focus{…}` first and the classic syntax second; `<Leader>Wd` detaches the buffer into a new side, `<Leader>Wn` opens an[m
[32m+[m[32mempty one, `<Leader>WH/J/K/L` send the buffer to the linked instance in that[m
[32m+[m[32mdirection by window geometry, `<Leader>Wa` sends it back to the main and[m
[32m+[m[32m`<Leader>Wi` lists the group. A buffer is wiped before it is sent, so the[m
 receiver never meets its swap file; that is why a modified buffer, one shown in[m
 a second window, or one a git review holds is refused instead. A side calls[m
 `core.session.disable()`, since it would otherwise restore or overwrite the[m
[36m@@ -1437,9 +1461,8 @@[m [mexception, justified per module.[m
 - **Done**: Rust, as `lua/lang/rust/`. rustaceanvim owns the rust-analyzer[m
   client, so the module has no `lsp` key — a second client from `vim.lsp.enable`[m
   would fight it. All three rustaceanvim executor slots route into `core.task`.[m
[31m-  Native rust-analyzer diagnostics see the unsaved buffer. After 800 ms without[m
[31m-  another edit, `core.autosave` writes an ordinary Rust file so check-on-save can[m
[31m-  run `cargo check`; Clippy remains the explicit *Lint with clippy* action.[m
[32m+[m[32m  Native rust-analyzer diagnostics see the unsaved buffer; check-on-save runs[m
[32m+[m[32m  `cargo check` whenever `core.autosave` or `:w` writes the file; Clippy remains the explicit *Lint with clippy* action.[m
   A reload from disk sends no `didSave`, so a file fixed outside the editor —[m
   Claude's edits included — kept the last check's `rustc` errors until the next[m
   `:w`; `flycheck.lua` sends `rust-analyzer/runFlycheck` on[m
[36m@@ -1449,7 +1472,7 @@[m [mexception, justified per module.[m
   green one stops it and starts the fresh binary. The trigger is an explicit[m
   `:w` of a `.rs` or `Cargo.toml` under the root and **never an autosave**, which[m
   `core.autosave.writing()` exists to tell apart — otherwise the program would[m
[31m-  restart every time you paused for 800 ms. Writes from outside the editor,[m
[32m+[m[32m  restart every time you switched buffers. Writes from outside the editor,[m
   Claude's included, do not trigger it. The build-only mode rebuilds and[m
   launches nothing, for a host process that reloads a dylib itself.[m
   Deliberately left behind: `dependencies.lua` (490 lines, crate search UI) is[m
[36m@@ -1486,7 +1509,11 @@[m [mexception, justified per module.[m
   `install-codecompanion-agents` and `store-codecompanion-claude-token` were[m
   deleted with it: they pinned an ACP bridge and a Node 22 runtime for a plugin[m
   that was never added, and the keyring script they installed never existed.[m
[31m-- **Port on demand**: Python, C++, notebooks, inlay hints, hover, and the two[m
[32m+[m[32m- **Done, partly**: C and C++, as `lua/lang/cpp/` — build, run and debug only.[m
[32m+[m[32m  See the section below. Deliberately not yet: `:CppNew` scaffolding,[m
[32m+[m[32m  "implement in the .cpp", the clangd refactor keys and the blink definition[m
[32m+[m[32m  source; those are the next C++ port when they are missed.[m
[32m+[m[32m- **Port on demand**: Python, notebooks, inlay hints, hover, and the two[m
   deferred Rust modules. Port one when it is first missed, rewritten to the[m
   contracts above rather than copied.[m
 - **Let die**: everything AstroNvim-shaped (`astrocore`, `astrolsp`, `astroui`,[m
[36m@@ -1513,6 +1540,48 @@[m [mWhen porting, rewrite to the new contract. Copying a file across and leaving it[m
 shaped like AstroNvim reintroduces exactly the inconsistency this rewrite[m
 exists to remove.[m
 [m
[32m+[m[32m## C and C++[m
[32m+[m
[32m+[m[32m`lua/lang/cpp/` declares `clangd` natively and one `<Leader>r` provider that[m
[32m+[m[32mpicks **one build system per buffer**: the outermost `CMakeLists.txt` inside the[m
[32m+[m[32mrepository wins, then the nearest Makefile, then the file on its own. Outermost,[m
[32m+[m[32mbecause a subdirectory's list is part of the project above it. The provider[m
[32m+[m[32malso answers in `cmake` and `make` buffers; clangd names its own filetypes and[m
[32m+[m[32mnever attaches there.[m
[32m+[m
[32m+[m[32mEach backend (`cmake.lua`, `make.lua`, `file.lua`) answers the same four[m
[32m+[m[32mquestions — `prepare`, `executables`, `build_executable`, `cwd` — and[m
[32m+[m[32m`actions.lua` builds Run and Debug on top of them, so *Build and run* means the[m
[32m+[m[32msame thing in all three. Everything runs through `core.task`; the program is[m
[32m+[m[32mstarted only from a green build's `on_exit`, with `queue = false` so a program[m
[32m+[m[32mleft running never holds the next build. Debug is `dap.run` against the plain[m
[32m+[m[32m`codelldb` that `adapters.lua` registers — there is no `dap` key, because no[m
[32m+[m[32mconfiguration can be known before the build. Every build writes the project's[m
[32m+[m[32mmodified buffers first: clangd sees the unsaved buffer, the compiler does not.[m
[32m+[m
[32m+[m[32m**CMake is driven directly, not through cmake-tools**: the old config's plugin[m
[32m+[m[32mhad its own executor that would compete with `core.task`. Build directories are[m
[32m+[m[32m`build/<BuildType>`, Ninja when it is installed (a generator is only passed to a[m
[32m+[m[32mfresh directory — CMake refuses to change it), and `compile_commands.json` is[m
[32m+[m[32msymlinked to the root after every configure so clangd follows the build type;[m
[32m+[m[32ma regular file already there is left alone. Targets come from the **File API**:[m
[32m+[m[32man empty `codemodel-v2` query makes every configure write the reply, which names[m
[32m+[m[32meach target's artifact and sources. That is how the target that compiles the[m
[32m+[m[32mcurrent file is offered first, with no parsing of `CMakeLists.txt`.[m
[32m+[m
[32m+[m[32m**Make has no metadata**, so its targets are read from `make -npq` and its[m
[32m+[m[32mexecutables are whatever ELF files sit under the root, newest first. Debugging[m
[32m+[m[32mneeds `-g` in the Makefile; nothing here can add it.[m
[32m+[m
[32m+[m[32mThe build type, the chosen executable and its arguments are remembered per[m
[32m+[m[32mroot **for the session only**, the same as Rust's watch. `<Leader>R` reuses[m
[32m+[m[32mthem rather than prompting.[m
[32m+[m
[32m+[m[32mA long compiler line wider than the task pane is hard-wrapped by the terminal,[m
[32m+[m[32mand a wrapped path does not parse into quickfix. That is `core.task`'s pty and[m
[32m+[m[32maffects every language; CMake shows it first because it compiles by absolute[m
[32m+[m[32mpath.[m
[32m+[m
 ## C# and Unity[m
 [m
 Two modules, not one. `lua/lang/csharp/` is C# on its own and must keep working[m
[1mdiff --git a/experimental/lua/core/autocmds.lua b/experimental/lua/core/autocmds.lua[m
[1mindex 0edcb35..aa19dd2 100644[m
[1m--- a/experimental/lua/core/autocmds.lua[m
[1m+++ b/experimental/lua/core/autocmds.lua[m
[36m@@ -43,9 +43,13 @@[m [mvim.api.nvim_create_autocmd("CursorMovedI", {[m
 })[m
 [m
 local autosave_group = augroup "autosave"[m
[31m-vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {[m
[32m+[m[32mvim.api.nvim_create_autocmd({ "BufLeave", "FocusLost" }, {[m
   group = autosave_group,[m
[31m-  callback = function(args) require("core.autosave").changed(args.buf) end,[m
[32m+[m[32m  callback = function() vim.schedule(require("core.autosave").flush) end,[m
[32m+[m[32m})[m
[32m+[m[32mvim.api.nvim_create_autocmd("QuitPre", {[m
[32m+[m[32m  group = autosave_group,[m
[32m+[m[32m  callback = function() require("core.autosave").on_quit() end,[m
 })[m
 vim.api.nvim_create_autocmd("BufWipeout", {[m
   group = autosave_group,[m
[1mdiff --git a/experimental/lua/core/autosave.lua b/experimental/lua/core/autosave.lua[m
[1mindex d31fb2a..e37e046 100644[m
[1m--- a/experimental/lua/core/autosave.lua[m
[1m+++ b/experimental/lua/core/autosave.lua[m
[36m@@ -1,16 +1,5 @@[m
 local M = {}[m
 [m
[31m----@class core.AutosaveConfig[m
[31m----@field delay? integer[m
[31m-[m
[31m----@class core.AutosaveState[m
[31m----@field generation integer[m
[31m----@field timer uv.uv_timer_t[m
[31m-[m
[31m----@type table<string, core.AutosaveConfig>[m
[31m-local filetypes = {}[m
[31m----@type table<integer, core.AutosaveState>[m
[31m-local states = {}[m
 ---@type table<integer, integer>[m
 local suspended = {}[m
 local writing = false[m
[36m@@ -28,19 +17,17 @@[m [mlocal function eligible(bufnr)[m
   end[m
   local bo = vim.bo[bufnr][m
   local name = vim.api.nvim_buf_get_name(bufnr)[m
[31m-  return filetypes[bo.filetype] ~= nil[m
[31m-    and bo.buftype == ""[m
[32m+[m[32m  return bo.buftype == ""[m
     and bo.modifiable[m
     and not bo.readonly[m
     and not in_diff(bufnr)[m
     and bo.modified[m
     and name ~= ""[m
     and not name:find("://", 1, true)[m
[32m+[m[32m    and not name:find("/.git/", 1, true)[m
 end[m
 [m
[31m-local function save(bufnr, generation)[m
[31m-  local state = states[bufnr][m
[31m-  if not state or state.generation ~= generation or not eligible(bufnr) then return end[m
[32m+[m[32mlocal function write(bufnr)[m
   writing = true[m
   local ok, err = pcall(vim.api.nvim_buf_call, bufnr, function() vim.cmd "silent update" end)[m
   writing = false[m
[36m@@ -50,38 +37,30 @@[m [mend[m
 ---@return boolean[m
 function M.writing() return writing end[m
 [m
[31m----@param filetype string[m
[31m----@param config? core.AutosaveConfig[m
[31m-function M.register(filetype, config)[m
[31m-  vim.validate("filetype", filetype, "string")[m
[31m-  config = config or {}[m
[31m-  vim.validate("delay", config.delay, "number", true)[m
[31m-  filetypes[filetype] = { delay = config.delay or 800 }[m
[32m+[m[32mfunction M.flush()[m
[32m+[m[32m  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do[m
[32m+[m[32m    if eligible(bufnr) then write(bufnr) end[m
[32m+[m[32m  end[m
 end[m
 [m
[31m----@param bufnr integer[m
[31m-function M.changed(bufnr)[m
[31m-  if not eligible(bufnr) then return end[m
[31m-  local config = filetypes[vim.bo[bufnr].filetype][m
[31m-  local state = states[bufnr][m
[31m-  if not state then[m
[31m-    local timer = vim.uv.new_timer()[m
[31m-    if not timer then return end[m
[31m-    state = { generation = 0, timer = timer }[m
[31m-    states[bufnr] = state[m
[32m+[m[32m-- 'autowriteall' is what lets `:q!` still discard, which a QuitPre flush cannot[m
[32m+[m[32m-- tell apart from `:q`; left on permanently it would also write on `:!` and[m
[32m+[m[32m-- <C-^>, which the Rust watcher would then read as an explicit `:w`.[m
[32m+[m[32mfunction M.on_quit()[m
[32m+[m[32m  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do[m
[32m+[m[32m    local bo = vim.bo[bufnr][m
[32m+[m[32m    if bo.modified and bo.buftype == "" and not bo.readonly and not eligible(bufnr) then return end[m
   end[m
[31m-  state.generation = state.generation + 1[m
[31m-  local generation = state.generation[m
[31m-  state.timer:stop()[m
[31m-  state.timer:start(config.delay or 800, 0, function() vim.schedule(function() save(bufnr, generation) end) end)[m
[32m+[m[32m  vim.o.autowriteall = true[m
[32m+[m[32m  writing = true[m
[32m+[m[32m  vim.schedule(function()[m
[32m+[m[32m    vim.o.autowriteall = false[m
[32m+[m[32m    writing = false[m
[32m+[m[32m  end)[m
 end[m
 [m
 ---@param bufnr integer[m
[31m-function M.suspend(bufnr)[m
[31m-  suspended[bufnr] = (suspended[bufnr] or 0) + 1[m
[31m-  local state = states[bufnr][m
[31m-  if state then state.timer:stop() end[m
[31m-end[m
[32m+[m[32mfunction M.suspend(bufnr) suspended[bufnr] = (suspended[bufnr] or 0) + 1 end[m
 [m
 ---@param bufnr integer[m
 function M.resume(bufnr)[m
[36m@@ -91,14 +70,6 @@[m [mfunction M.resume(bufnr)[m
 end[m
 [m
 ---@param bufnr integer[m
[31m-function M.forget(bufnr)[m
[31m-  local state = states[bufnr][m
[31m-  if state then[m
[31m-    state.timer:stop()[m
[31m-    state.timer:close()[m
[31m-    states[bufnr] = nil[m
[31m-  end[m
[31m-  suspended[bufnr] = nil[m
[31m-end[m
[32m+[m[32mfunction M.forget(bufnr) suspended[bufnr] = nil end[m
 [m
 return M[m
[1mdiff --git a/experimental/lua/core/cheatsheet.lua b/experimental/lua/core/cheatsheet.lua[m
[1mindex cbfe44a..777b3fd 100644[m
[1m--- a/experimental/lua/core/cheatsheet.lua[m
[1m+++ b/experimental/lua/core/cheatsheet.lua[m
[36m@@ -143,8 +143,11 @@[m [mlocal SECTIONS = {[m
     {[m
       { "<C-h/j/k/l>", "move between windows, terminal included" },[m
       { "<C-Up/Down/Left/Right>", "resize this window, terminal included" },[m
[31m-      { "<Leader>wv / wh", "split vertically / horizontally" },[m
[31m-      { "<Leader>wc / wo", "close this window / close the others" },[m
[32m+[m[32m      { "<C-w>v / <C-w>s", "split vertically / horizontally" },[m
[32m+[m[32m      { "<C-w>c / <C-w>o", "close this window / close the others" },[m
[32m+[m[32m      { "<Leader>w", "write this buffer" },[m
[32m+[m[32m      { "jj jk kj kk  (insert)", "leave insert mode, typed quickly" },[m
[32m+[m[32m      { "autosave", "changed files are written on buffer leave, focus loss and quit" },[m
       { "<Leader>bd", "delete this buffer" },[m
       { "<Leader>t", "toggle a shell in the bottom pane" },[m
       { "<Esc><Esc>  (terminal)", "leave terminal input mode" },[m
[1mdiff --git a/experimental/lua/core/keymaps.lua b/experimental/lua/core/keymaps.lua[m
[1mindex fb502cc..16b5ce5 100644[m
[1m--- a/experimental/lua/core/keymaps.lua[m
[1m+++ b/experimental/lua/core/keymaps.lua[m
[36m@@ -17,11 +17,32 @@[m [mfor lhs, spec in pairs(motions) do[m
   map({ "n", "x", "o" }, lhs, rhs, { desc = desc, remap = recursive })[m
 end[m
 [m
[31m--- `|` and `\` both need AltGr on a Danish layout, so splits get a leader path too.[m
[31m-map("n", "<Leader>wv", "<Cmd>vsplit<CR>", { desc = "Vertical split" })[m
[31m-map("n", "<Leader>wh", "<Cmd>split<CR>", { desc = "Horizontal split" })[m
[31m-map("n", "<Leader>wc", "<Cmd>close<CR>", { desc = "Close window" })[m
[31m-map("n", "<Leader>wo", "<Cmd>only<CR>", { desc = "Close other windows" })[m
[32m+[m[32mmap("n", "<Leader>w", "<Cmd>write<CR>", { desc = "Write" })[m
[32m+[m
[32m+[m[32mlocal ESCAPE_WINDOW_NS = 200e6[m
[32m+[m[32mlocal escape_pending[m
[32m+[m[32m-- A plain `inoremap jj <Esc>` holds back every `j` for 'timeoutlen'; this[m
[32m+[m[32m-- inserts it at once and takes it back if the second key follows in time.[m
[32m+[m[32mfor _, key in ipairs { "j", "k" } do[m
[32m+[m[32m  map("i", key, function()[m
[32m+[m[32m    local now = vim.uv.hrtime()[m
[32m+[m[32m    local row, col = unpack(vim.api.nvim_win_get_cursor(0))[m
[32m+[m[32m    local bufnr = vim.api.nvim_get_current_buf()[m
[32m+[m[32m    local previous = escape_pending[m
[32m+[m[32m    escape_pending = { bufnr = bufnr, row = row, col = col + 1, time = now }[m
[32m+[m[32m    if[m
[32m+[m[32m      previous[m
[32m+[m[32m      and previous.bufnr == bufnr[m
[32m+[m[32m      and previous.row == row[m
[32m+[m[32m      and previous.col == col[m
[32m+[m[32m      and now - previous.time < ESCAPE_WINDOW_NS[m
[32m+[m[32m    then[m
[32m+[m[32m      escape_pending = nil[m
[32m+[m[32m      return "<BS><Esc>"[m
[32m+[m[32m    end[m
[32m+[m[32m    return key[m
[32m+[m[32m  end, { expr = true, desc = "Insert " .. key .. ", or leave insert mode after j/k" })[m
[32m+[m[32mend[m
 [m
 -- <C-l> is taken for window navigation below, and it was the default way to[m
 -- clear multicursors (|mcursor-clear|). Clearing the namespace is the[m
[1mdiff --git a/experimental/lua/lang/rust/actions.lua b/experimental/lua/lang/rust/actions.lua[m
[1mindex d6eabcd..5afd97a 100644[m
[1m--- a/experimental/lua/lang/rust/actions.lua[m
[1m+++ b/experimental/lua/lang/rust/actions.lua[m
[36m@@ -257,13 +257,14 @@[m [mreturn {[m
       label = "Run a binary target",[m
       category = "Run",[m
       available = buildable_here,[m
[31m-      repeatable = false,[m
[31m-      run = function()[m
[31m-        pick_binary([m
[31m-          ctx,[m
[31m-          "Run which binary?",[m
[31m-          function(_, binary) cargo_task(ctx, "cargo run " .. binary, { "run", "--bin", binary }) end[m
[31m-        )[m
[32m+[m[32m      run = function(_, opts)[m
[32m+[m[32m        local function run(binary)[m
[32m+[m[32m          vim.b[ctx.bufnr].rust_run_bin = binary[m
[32m+[m[32m          cargo_task(ctx, "cargo run " .. binary, { "run", "--bin", binary })[m
[32m+[m[32m        end[m
[32m+[m[32m        local last_bin = vim.b[ctx.bufnr].rust_run_bin[m
[32m+[m[32m        if opts.repeated and last_bin then return run(last_bin) end[m
[32m+[m[32m        pick_binary(ctx, "Run which binary?", function(_, binary) run(binary) end)[m
       end,[m
     }[m
 [m
[1mdiff --git a/experimental/lua/lang/rust/init.lua b/experimental/lua/lang/rust/init.lua[m
[1mindex 988760f..f5bce98 100644[m
[1m--- a/experimental/lua/lang/rust/init.lua[m
[1m+++ b/experimental/lua/lang/rust/init.lua[m
[36m@@ -9,7 +9,6 @@[m [mreturn {[m
       "mrcjkb/rustaceanvim",[m
       lazy = false,[m
       init = function()[m
[31m-        require("core.autosave").register("rust", { delay = 800 })[m
         require("lang.rust.lens").setup()[m
         require("lang.rust.flycheck").setup()[m
         local cargo = require "lang.rust.cargo"[m
[1mdiff --git a/experimental/lua/plugins/key-hints/control.lua b/experimental/lua/plugins/key-hints/control.lua[m
[1mindex 2470659..6814b3b 100644[m
[1m--- a/experimental/lua/plugins/key-hints/control.lua[m
[1m+++ b/experimental/lua/plugins/key-hints/control.lua[m
[36m@@ -67,7 +67,6 @@[m [mfunction M.setup()[m
       { "<Leader>f", group = "Find" },[m
       { "<Leader>s", group = "Search" },[m
       { "<Leader>u", group = "Toggle" },[m
[31m-      { "<Leader>w", group = "Window" },[m
     },[m
   }[m
 [m
[1mdiff --git a/experimental/lua/user/init.lua b/experimental/lua/user/init.lua[m
[1mindex b3519de..209bba2 100644[m
[1m--- a/experimental/lua/user/init.lua[m
[1m+++ b/experimental/lua/user/init.lua[m
[36m@@ -28,15 +28,15 @@[m [mif vim.uv.fs_stat(detach_path) then[m
     )[m
     vim.keymap.set([m
       "n",[m
[31m-      "<Leader>w" .. key:upper(),[m
[32m+[m[32m      "<Leader>W" .. key:upper(),[m
       function() detach.send(key) end,[m
       { desc = "Send buffer to the instance " .. key }[m
     )[m
   end[m
[31m-  vim.keymap.set("n", "<Leader>wd", detach.detach, { desc = "Detach buffer to a new instance" })[m
[31m-  vim.keymap.set("n", "<Leader>wn", detach.spawn, { desc = "New linked instance" })[m
[31m-  vim.keymap.set("n", "<Leader>wa", detach.attach, { desc = "Send buffer back to the main instance" })[m
[31m-  vim.keymap.set("n", "<Leader>wi", detach.list, { desc = "Linked instances" })[m
[32m+[m[32m  vim.keymap.set("n", "<Leader>Wd", detach.detach, { desc = "Detach buffer to a new instance" })[m
[32m+[m[32m  vim.keymap.set("n", "<Leader>Wn", detach.spawn, { desc = "New linked instance" })[m
[32m+[m[32m  vim.keymap.set("n", "<Leader>Wa", detach.attach, { desc = "Send buffer back to the main instance" })[m
[32m+[m[32m  vim.keymap.set("n", "<Leader>Wi", detach.list, { desc = "Linked instances" })[m
 [m
   require("core.statusline").register("detach", {[m
     side = "right",[m
[1mdiff --git a/experimental/scripts/autosave-smoke.lua b/experimental/scripts/autosave-smoke.lua[m
[1mindex 64c3ed0..93d72b4 100644[m
[1m--- a/experimental/scripts/autosave-smoke.lua[m
[1m+++ b/experimental/scripts/autosave-smoke.lua[m
[36m@@ -1,39 +1,65 @@[m
 vim.opt.runtimepath:prepend(vim.fn.getcwd())[m
 [m
[31m-local path = vim.fn.tempname() .. ".rs"[m
[32m+[m[32mlocal dir = vim.fn.tempname()[m
[32m+[m[32mlocal path = dir .. "/main.rs"[m
[32m+[m[32mlocal other = dir .. "/other.rs"[m
[32m+[m[32mlocal commit = dir .. "/.git/COMMIT_EDITMSG"[m
 [m
[31m-local function cleanup() pcall(vim.uv.fs_unlink, path) end[m
[32m+[m[32mlocal function cleanup() vim.fs.rm(dir, { recursive = true, force = true }) end[m
[32m+[m
[32m+[m[32mlocal function on_disk(file, text) return vim.fn.readfile(file)[1]:find(text, 1, true) ~= nil end[m
 [m
 local ok, err = xpcall(function()[m
[32m+[m[32m  vim.fs.mkdir(dir .. "/.git", { parents = true })[m
   vim.fn.writefile({ "fn main() {}" }, path)[m
[31m-  require("core.autosave").register("rust", { delay = 20 })[m
[32m+[m[32m  vim.fn.writefile({ "fn other() {}" }, other)[m
[32m+[m[32m  vim.fn.writefile({ "" }, commit)[m
   require "core.autocmds"[m
 [m
   vim.cmd.edit(vim.fn.fnameescape(path))[m
   local bufnr = vim.api.nvim_get_current_buf()[m
[31m-  vim.bo[bufnr].filetype = "rust"[m
   vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "fn main() { let live = true; }" })[m
   vim.api.nvim_exec_autocmds("TextChanged", { buffer = bufnr })[m
[31m-  assert(vim.wait(500, function() return not vim.bo[bufnr].modified end), "idle save did not finish")[m
[31m-  assert(vim.fn.readfile(path)[1]:find("live", 1, true), "idle save did not reach disk")[m
[32m+[m[32m  vim.wait(100)[m
[32m+[m[32m  assert(not on_disk(path, "live"), "an edit alone reached disk")[m
[32m+[m
[32m+[m[32m  vim.cmd.edit(vim.fn.fnameescape(other))[m
[32m+[m[32m  assert(vim.wait(500, function() return not vim.bo[bufnr].modified end), "leaving the buffer did not save it")[m
[32m+[m[32m  assert(on_disk(path, "live"), "leave save did not reach disk")[m
[32m+[m
[32m+[m[32m  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "fn main() { let hidden = true; }" })[m
[32m+[m[32m  vim.api.nvim_exec_autocmds("FocusLost", {})[m
[32m+[m[32m  assert(vim.wait(500, function() return not vim.bo[bufnr].modified end), "focus loss did not save a hidden buffer")[m
[32m+[m[32m  assert(on_disk(path, "hidden"), "hidden save did not reach disk")[m
 [m
   require("core.autosave").suspend(bufnr)[m
   vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "fn main() { let held = true; }" })[m
[31m-  vim.api.nvim_exec_autocmds("TextChanged", { buffer = bufnr })[m
[32m+[m[32m  vim.api.nvim_exec_autocmds("FocusLost", {})[m
   vim.wait(100)[m
[31m-  assert(not vim.fn.readfile(path)[1]:find("held", 1, true), "suspended autosave reached disk")[m
[32m+[m[32m  assert(not on_disk(path, "held"), "suspended autosave reached disk")[m
 [m
   require("core.autosave").resume(bufnr)[m
[31m-  vim.api.nvim_exec_autocmds("TextChanged", { buffer = bufnr })[m
[32m+[m[32m  vim.api.nvim_exec_autocmds("FocusLost", {})[m
   assert(vim.wait(500, function() return not vim.bo[bufnr].modified end), "resumed save did not finish")[m
[31m-  assert(vim.fn.readfile(path)[1]:find("held", 1, true), "resumed save did not reach disk")[m
[32m+[m
[32m+[m[32m  vim.cmd.edit(vim.fn.fnameescape(commit))[m
[32m+[m[32m  local commit_buf = vim.api.nvim_get_current_buf()[m
[32m+[m[32m  vim.api.nvim_buf_set_lines(commit_buf, 0, -1, false, { "message" })[m
[32m+[m[32m  vim.api.nvim_exec_autocmds("FocusLost", {})[m
[32m+[m[32m  vim.wait(100)[m
[32m+[m[32m  assert(vim.bo[commit_buf].modified, "a buffer under .git was written")[m
[32m+[m
[32m+[m[32m  vim.api.nvim_exec_autocmds("QuitPre", {})[m
[32m+[m[32m  assert(not vim.o.autowriteall, "quit borrowed autowriteall past an ineligible buffer")[m
[32m+[m[32m  vim.bo[commit_buf].modified = false[m
[32m+[m[32m  vim.api.nvim_exec_autocmds("QuitPre", {})[m
[32m+[m[32m  assert(vim.o.autowriteall and require("core.autosave").writing(), "quit did not borrow autowriteall")[m
[32m+[m[32m  vim.wait(50)[m
[32m+[m[32m  assert(not vim.o.autowriteall, "autowriteall outlived the quit")[m
 end, debug.traceback)[m
 [m
[31m-if not ok then[m
[31m-  cleanup()[m
[31m-  error(err)[m
[31m-end[m
[32m+[m[32mcleanup()[m
[32m+[m[32mif not ok then error(err) end[m
 [m
[31m-vim.uv.fs_unlink(path)[m
 print "AUTOSAVE_SMOKE_OK"[m
 vim.cmd "qa!"[m
[1mdiff --git a/experimental/scripts/check.sh b/experimental/scripts/check.sh[m
[1mindex 8e0053a..5ffe0b4 100755[m
[1m--- a/experimental/scripts/check.sh[m
[1m+++ b/experimental/scripts/check.sh[m
[36m@@ -68,9 +68,9 @@[m [mif [[ -x $nvim_bin ]]; then[m
   autosave=$("$nvim_bin" --headless -u NONE -l scripts/autosave-smoke.lua 2>&1)[m
   if grep -q 'AUTOSAVE_SMOKE_OK' <<<"$autosave" &&[m
     ! grep -qE 'Error detected|stack traceback|E[0-9]+:' <<<"$autosave"; then[m
[31m-    say PASS "idle autosave smoke"[m
[32m+[m[32m    say PASS "autosave smoke"[m
   else[m
[31m-    say FAIL "idle autosave smoke"[m
[32m+[m[32m    say FAIL "autosave smoke"[m
     sed 's/^/        /' <<<"$autosave" | head -20[m
   fi[m
 [m
[1mdiff --git a/lua/user/context/init.lua b/lua/user/context/init.lua[m
[1mindex c1d9965..3d72716 100644[m
[1m--- a/lua/user/context/init.lua[m
[1m+++ b/lua/user/context/init.lua[m
[36m@@ -180,7 +180,7 @@[m [mfunction M.status()[m
 end[m
 [m
 function M.setup()[m
[31m-  for _, name in ipairs { "tasks", "python", "notebook", "rust", "cpp", "cmake", "unity", "http" } do[m
[32m+[m[32m  for _, name in ipairs { "tasks", "python", "notebook", "rust", "cpp", "cmake", "make", "unity", "http" } do[m
     M.register(require("user.context.providers." .. name))[m
   end[m
 end[m
