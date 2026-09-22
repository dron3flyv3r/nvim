# Neovim configuration (experimental)

A vanilla Neovim config built from scratch on nightly 0.13, using lazy.nvim for
plugins and snacks.nvim as the base layer. It lives beside the old AstroNvim
config in the same repository and is launched with `nv`, which sets
`NVIM_APPNAME=nvim/experimental` so config, data, state and cache are fully
isolated from the main install.

This document is the contract. Read it before changing anything here. Where it
disagrees with the code, the code is wrong.

## Why this config exists

The previous config worked but accumulated several competing approaches to the
same problems: three ways to declare a keymap, options set in four places,
language support smeared across plugin specs. The point of this rewrite is
**one way to do each thing**. A new reader should be able to predict which file
a given behaviour lives in without searching.

Consistency outranks convenience here. A slightly more verbose pattern that is
used everywhere beats a shortcut that is used in half the files.

## Requirements

Neovim **0.13+**, hard-required. `init.lua` refuses to start on anything older
rather than degrading. The nightly is managed by the justfile and installed to
`~/.local/share/nvim-versions/<version>/`, with a `current` symlink that `nv`
follows. The system `/usr/bin/nvim` is left alone and still serves the old
config.

Because 0.13 is a hard floor, **prefer built-ins to plugins**. Use
`vim.lsp.config`/`vim.lsp.enable` rather than `nvim-lspconfig` glue, native
treesitter and native LSP folding, `vim.o` rather than `vim.opt` where the
value is a scalar. A plugin needs to earn its place by doing something the
editor cannot.

## Layout

```
init.lua              version guard, leader, lazy bootstrap, handoff
justfile              nightly install, `nv` alias, maintenance recipes
AGENTS.md             this file (CLAUDE.md is a symlink to it)
lua/
  core/               the configuration itself, no plugins involved
    options.lua       vim.o / vim.opt
    diagnostics.lua   vim.diagnostic.config and the inline-scope toggle
    autosave.lua      registered filetypes, idle timers and suspensions
    codelens.lua      the global code lens state and its suspensions
    colorscheme.lua   the remembered colourscheme and its fallback
    keymaps.lua       keymaps that do not belong to a plugin
    autocmds.lua      autocommands
    actions.lua       the <Leader>r provider/action registry
    statusline.lua    the global statusline and its component registry
    session.lua       native project session persistence
    terminal.lua      an interactive shell in the shared bottom strip
    macros.lua        the recording indicator and the macro list
    lang.lua          loader for lua/lang
    utf8_guard.lua    masks invalid UTF-8 in didChange payloads
    pane.lua          the one bottom strip, shared by its occupants
    task/             the execution layer: run, queue, output
  plugins/            global plugin specs, one concern per file
  lang/               per-language modules, one file per language
  user/               per-device overrides (git submodule, optional)
scripts/check.sh      the gates behind `just check`
```

### Load order

`core` → `plugins` → `lang` → `user`, strictly one-directional. A later layer
may override an earlier one; an earlier layer must never reach forward into a
later one.

| Layer | May depend on | Must not |
| --- | --- | --- |
| `core` | Neovim only | `require` any plugin, name any language |
| `plugins` | `core` | name a specific language or device |
| `lang` | `core`, `plugins` | be device-specific, register global keymaps |
| `user` | anything | be required by anything else |

The practical test: deleting `lua/user` entirely must leave a working config,
and deleting `lua/lang` must leave a working editor.

## `lua/core`

Everything that would still make sense with no plugins installed. If a setting
survives `rm -rf lua/plugins`, it belongs here.

`options.lua`, `keymaps.lua` and `autocmds.lua` are the only places those three
things are declared. A plugin spec may declare keys in its own `keys = {}`
table — that is lazy.nvim's lazy-loading mechanism and is fine — but it must
not write into a shared global keymap table. There is no `polish.lua` and no
late-running fixup file; if something needs to happen after startup, it is a
named autocommand in `autocmds.lua`.

`cheatsheet.lua` is `<F1>` and `:Cheatsheet`: the config's own additions plus
the native patterns it assumes you use instead of a multicursor. It is
hand-written, which means **it goes stale silently** — change a mapping and it
is your job to change the page. It stays in `core` because it is a float and a
scratch buffer with no plugin involved; the one dynamic section reads
`core.actions`, which is also core. Pad columns with `strdisplaywidth`, not
`%-22s`: `æ ø … ·` all break byte-based padding.

## `lua/plugins`

One file per plugin or per tightly-coupled group, returning a `LazySpec`.
Filenames are kebab-case and named after the *concern*, not the vendor:
`git/`, not `gitsigns.lua`, so swapping the implementation does not rename
the file. Lazy imports the directory; no index file lists them.

snacks.nvim is the base layer and replaces what would otherwise be seven
separate plugins (picker, explorer, dashboard, notifier, statuscolumn, terminal,
buffer delete). Before adding a plugin, check whether snacks already does it. If
it does, use snacks even if the dedicated plugin is marginally better — see the
consistency rule above. Git is the one place that answer was overruled, and the
Git section says why.

No spec is added "to try out"; this config is the result of deleting one that
grew that way. The filename states what the plugin is for, which is why the
files are named after concerns.

`colorscheme.lua` is tokyonight, onedark and atom-dark. tokyonight is the
default and the only one loaded eagerly, at `priority = 1000` so it is in place
before any other UI plugin draws; the other two are `lazy = true` and are
brought in by lazy's own `ColorSchemePre` handler when their scheme is named,
which `<Leader>uC` reaches because snacks' picker globs an unloaded plugin's
`colors/` directory. It sets the scheme in `config` rather than leaving it to
`init.lua`; `lazy.setup`'s `install.colorscheme` only themes lazy's own install
window and sets nothing.

**The choice survives the session.** `core/colorscheme.lua` is the one writer:
it reads `stdpath("state")/colorscheme` and applies it, then records every
`ColorScheme` event, so `:colorscheme` typed by hand persists exactly as the
picker does. `core` names no scheme -- the plugin layer passes the default in.
The record is debounced by 300 ms, because the picker previews by *applying*
the scheme under the cursor and so fires one event per keypress; only the last
of them is a choice, and cancelling restores the original as one more event.
A stored scheme that no longer loads falls back to the default and is **left on
disk**, so reinstalling the plugin restores the choice rather than needing it
picked again.

snacks' picker owns `vim.ui.select` (`ui_select` defaults to true), so every
`vim.ui.select` call in this config — `<Leader>r`, any language module's prompt
— renders through it for free.

`focus = "list"` is set on `select` and on the four `lsp_*` location sources,
because those lists are short and rarely need filtering: the cursor starts in
the results, `j`/`k` work with no mode change, and `i` or `/` reaches the
filter when it is genuinely wanted. Pickers that exist to be typed into —
files, grep — keep the default prompt focus, where `<C-j>`/`<C-k>` move the
selection. That split is the rule; apply it to new sources by asking whether
the list is browsed or searched.

The `<Leader>r` menu is the one `select` that is *searched*, and it says so
through `kind`. `core.actions` passes `kind = "action"` — a documented
`vim.ui.select` field, so `core` still names no plugin — and
`picker.sources.select.kinds.action` is where the plugin layer decides what that
means: prompt focus, and `<Tab>`/`<S-Tab>` rebound from `select_and_next`/`prev`
to `list_down`/`list_up`, because a menu with 34 entries across seven categories
is filtered by typing `debug` rather than scrolled to. Multi-selection has no
meaning here — one action runs — so those two keys are free to move the cursor.
That is the mechanism for any future per-kind treatment: a new `kind`, not a
change to the shared `select` config.

`grapple.lua` is the file list: a handful of files per git repository,
persisted to `stdpath("data")/grapple` and reachable by index. It is
deliberately coarse and does not replace marks — marks and `<Leader>sm` still
answer "this exact line". It was chosen over harpoon for the per-repository
scoping and the editable menu; the cost is that upstream has been unmaintained
since 2024-09-29, so the lockfile pin is the version that matters.

`nvim-web-devicons` is a dependency rather than a spec of its own. grapple's
`tag_content.lua` raises a hard `error` when it is missing and `icons` is on,
and both snacks and which-key find it too, so one plugin serves all three.

`pairs.lua` is mini.pairs, and it is the one thing here the editor genuinely
cannot do: there is no native auto-pairing. `(`, `[`, `{` and `"` open a pair,
and typing the closing character where one already sits **moves over it** rather
than inserting a second — which is the whole point, since the alternative is
reaching for an arrow key. `'` and `` ` `` are mapped to `false`: an apostrophe
in prose and a C# char literal are the common cases, and neither wants a pair.

It also claims `<BS>` and `<CR>` in insert mode, from its own `ensure_cr_bs` —
backspace inside an empty pair deletes both halves, and `<CR>` between them puts
the closing half on its own line. Both are skipped if a mapping is already
there, so **whoever binds insert-mode `<CR>` has to reproduce `MiniPairs.cr()`**
or brace-and-Enter stops indenting. blink's default preset leaves `<CR>` alone,
which is why nothing fights over it today.

A prompt is not a buffer: `foo(` typed into a picker is a search term, and
closing it turns the search into something else. `vim.b.minipairs_disable` is
set for `snacks_picker_input` and `snacks_input` from the spec's `init`, not its
`config`, because the picker has already set its filetype by the time the first
`InsertEnter` loads the plugin.

`key-hints/` is which-key, disabled by default and toggled with `<Leader>uH`.
Disabling it removes its triggers rather than merely hiding the window, so key
sequences behave exactly as they did before it loaded. The checked-in user
override enables it for this device; deleting `lua/user` restores the default.

`lsp.lua` owns the LSP keymaps. They are in the plugin layer rather than in
`core/keymaps.lua` because they call the snacks picker, and `core` may not
require a plugin. The file registers its `LspAttach` autocommand at import time
and returns only `{ "folke/snacks.nvim", optional = true }` as a dependency
marker. It must not carry `init` or `config`: lazy merges specs with
`Util.merge`, which *replaces* rather than merges function fields, so a second
`init` for snacks here would silently delete the one in `snacks.lua`.

`tools.lua` is mason, and it is the **only** way external tooling is installed
from inside the editor. It is deliberately thin: no `mason-lspconfig`, no
`ensure_installed` list, no bridge of any kind. A server is installed by hand
with `:MasonInstall`, and a language module then finds it on `PATH` exactly as
it would find one installed by a package manager — mason is a downloader, not a
layer that servers are declared through. Declaring a server is still the `lsp`
key in `lua/lang`, and nothing in `lua/lang` may name mason.

The install root is `stdpath("data")/mason`, which under `NVIM_APPNAME` is
`~/.local/share/nvim/experimental/mason` — a different tree from the old
config's, so the two never fight over a version.

**`init.lua` prepends `stdpath("data")/mason/bin` to `PATH`, not mason.** Its
own `PATH` handling runs inside `mason.setup()`, which lazy cannot reach until
`lazy.setup()`, and `lang.specs()` runs before that — a language module probes
for its binary while it is being required, so a spec-driven prepend would
always arrive too late and a mason-installed server would never be detected.
The spec therefore sets `PATH = "skip"`; `init.lua` is the one writer. The
consequence to state plainly: a server installed during a session is picked up
on the **next** start, not immediately.

## `lua/lang`

One file per language, returning a plain declarative table with up to five
known keys and no others:

```lua
---@type lang.Module
return {
  ft = { "rust" },
  lsp = {
    rust_analyzer = { settings = { ... } },
  },
  dap = {
    adapters = { codelldb = { ... } },
    configurations = function(bufnr) ... end,
  },
  plugins = {
    { "mrcjkb/rustaceanvim", ft = "rust", opts = { ... } },
  },
  actions = {
    name = "Rust",
    priority = 80,
    detect = function(ctx) ... end,
    actions = function(ctx) ... end,
  },
}
```

`lsp` is merged into `vim.lsp.config` and enabled; `plugins` are `LazySpec`
fragments handed to lazy.nvim; `actions` is a `<Leader>r` provider; `dap` is
handed to the debug layer.

`lua/core/lang.lua` walks the directory and applies four of the five keys.
`plugins` must be collected before `lazy.setup()`, which needs the whole spec up
front. Neither `lsp` nor `actions` needs a deferral mechanism of its own:
`vim.lsp.enable` already waits for a matching filetype before starting a server,
and an action provider is an inert table until `<Leader>r` resolves the context.
A module whose *implementation* is expensive keeps that cost inside its action
closures, not at the top of the file.

`dap` is the exception, and it is **collected, not applied**: `core.lang.dap_specs()`
returns the declarations and `plugins/debug/adapters.lua` is what hands them to
nvim-dap, because `core` may not require a plugin. A `configurations` **function**
becomes a named `dap.providers.configs` entry — named so re-applying replaces
rather than stacks — and is only asked about buffers whose filetype the module
claims. A `configurations` **table** is appended to `dap.configurations[ft]` for
each of those filetypes instead.

`ft` doubles as the default `filetypes` for every server in `lsp`, so the
filetype list is written once. Language modules never call `lazy.setup`, never
call `vim.lsp.enable` themselves and never register a keymap.

Unknown keys are a hard error: `core.lang` refuses the module and says which
key was wrong, rather than silently ignoring it. A module that fails to load is
reported and skipped — one broken language must not cost you an editor.

A language larger than one screenful gets a directory: `lua/lang/unity/` with
`init.lua` returning the module table and the implementation split beside it.
The five-key contract is unchanged.

## `<Leader>r` — the action system

`<Leader>r` opens the actions valid in the current buffer and project. It is
the **only** entry point a language module gets. This is the rule that keeps
the keymap space from fragmenting the way it did before, where each language
claimed its own prefix and none of them behaved alike.

The registry in `lua/core/actions.lua` owns two types:

```lua
---@class core.ActionProvider
---@field id string           unique, stable
---@field name string         shown as the group heading
---@field priority? integer   higher sorts first
---@field detect fun(ctx): boolean|string   string doubles as a detail line
---@field actions fun(ctx): core.Action[]
---@field status? fun(ctx): string[]        extra lines for :ActionsStatus

---@class core.Action
---@field id string           unique within the provider
---@field label string        imperative, sentence case: "Run the test under the cursor"
---@field category? string    groups within a provider: Build, Test, Debug, Inspect
---@field priority? integer
---@field available? boolean|string|fun(ctx): boolean|string
---@field repeatable? boolean set false to keep it out of <Leader>R
---@field run fun(ctx)
```

`available` returning a **string** is the important detail: the action stays
visible and explains why it cannot run right now, instead of silently
vanishing. "No Cargo.toml above this file" teaches; an absent menu entry does
not. Use it.

Prefer the **function** form of `available`. A plain value is evaluated while
the menu is being built and is stale by the time it is read; a function is
re-checked when the menu opens. Check the thing you actually need, not a proxy
for it — the Rust provider once tested `vim.fn.exists ":RustLsp"`, which is a
global command that exists even in a buffer with no client attached, and so
reported ready when nothing could answer.

`<Leader>R` repeats the last executed action. An action that is not meaningfully
repeatable (opening a picker, showing docs) sets `repeatable = false`.

`run` receives a second argument, `opts`, whose only field is `repeated` — true
when `<Leader>R` re-ran the action rather than the menu choosing it. An action that
prompts uses it to skip the prompt and reuse its last answer, which is what makes
`<Leader>R` mean *run it again* rather than *ask me again*. Anything an action
remembers for that purpose must be read **inside** `run`: the closure in the menu
was built before the run that set it.

Categories are drawn from a fixed vocabulary so that muscle memory transfers
between languages: **Build**, **Run**, **Test**, **Debug**, **Refactor**,
**Inspect**, **Maintenance**. A Rust build and a Unity compile appear under the same
heading, and the menu lists them in that order rather than alphabetically, so
the shape of the menu does not change with the language. Anything outside the
vocabulary is filed under Inspect and warns once, naming the action. Add a new
category only when nothing existing fits — add it to `M.CATEGORIES` and to this
list, in that order.

Three commands mirror the keys: `:Actions`, `:ActionsRepeat`, `:ActionsStatus`.
The last one explains what was detected and why any unavailable action is
unavailable, and is the first thing to reach for when `<Leader>r` is emptier
than expected.

## Execution

`core.task` runs every external process whose **output you watch** — a build, a
test run, a log tail, the editor itself. A language module never calls
`jobstart` or `:!` for one of those, so that output, queueing and quickfix
behave the same whatever started it.

A short probe read for its *value* is not a task and must not become one: a
pane that opens to show three lines of `adb devices` is noise, and the caller
wants the parsed answer rather than a buffer. Those are a plain
`vim.system(...):wait()` with a timeout — `unity/bridge.lua`'s `git
check-ignore` and everything in `unity/android/device.lua`. The test is whether
a human is meant to read the output, not how long the process runs.

```lua
require("core.task").run {
  name = "cargo build",
  cmd = { "cargo", "build" },
  cwd = workspace_root,
  errorformat = "%f:%l:%c: %trror: %m",
  queue = true,
  focus = false,
  on_exit = function(task) ... end,
}
```

`cmd` is an argv list, never a shell string — no quoting bugs, no shell needed.

**Queueing is the default.** A second task waits for the running one instead of
competing with it for the same target directory. Pass `queue = false` for
something genuinely independent, such as a watcher or a server.

**Output is a real pty** (`jobstart` with `term = true`), so colours, progress
bars and interactive prompts work. It lands in `core.pane`, the strip described
below, as the occupant named `task`. There, normal-mode `h` hides it and leaves
the task running; `q` stops the task and hides it. Both are normal-mode only,
because in terminal mode those letters are input to the process.

### `core.pane` — the one bottom strip

There is **exactly one bottom window per tab**, full width, `winfixheight` so
other splits cannot squeeze it, and `core.pane` owns it. Anything that wants to
show a scrolling buffer down there registers as a named occupant and claims the
slot; the window is found again by its `core_pane` window variable rather than by
sniffing the buffer, because more than one kind of buffer lives there now.

```lua
require("core.pane").show({
  name = "task",
  bufnr = bufnr,
  close = function() ... end,   -- what `q` means for this occupant
}, { enter = true, insert = false })
```

`h` hides the strip from any occupant, `q` runs that occupant's `close`, and
`<Tab>`/`<S-Tab>` cycle between them. Occupants today are `terminal`, `task`,
and the debugger's `repl` and `program`. This is why dap-ui is configured with a left panel and no
bottom dock: a second full-width strip would compete with this one, and during a
session you still rebuild — the contract that a failing task opens the pane has
to keep holding while the debugger is up.

Claiming the slot is the *last* writer's privilege, which is deliberate: a
failing build is what you want to be looking at the moment it fails.

**A failing task opens the pane; a succeeding one stays quiet.** Do not add
success notifications.

**`errorformat` is the whole quickfix story.** Give one and the output is parsed
on exit, resolved against the *task's* `cwd` rather than Neovim's — compilers
print paths relative to where they ran. Omit it and quickfix is left alone.

`core.task` registers its own `<Leader>r` provider (show last output, restart,
stop, clear queue) and the commands `:TaskOutput`, `:TaskStop`, `:TaskRestart`.

### Sessions and the terminal

`core.session` stores one native session per Git repository, falling back to the
startup directory outside Git. `VimLeavePre` saves file-backed buffers, tabs,
splits, sizes, folds and local options under `stdpath("state")`. Temporary panes,
terminals and help windows are excluded. `:SessionSave`, `:SessionRestore` and
`:SessionDelete` provide manual control.

**A buffer whose name is a URI never survives a session.** `mksession` writes
`edit diffview://…` for a review that was on screen at exit, and sourcing that
back creates an ordinary *empty* file buffer holding the name. Diffview's
`File.create_buffer` then does `find_named_buffer(fullname)` and returns the
buffer it found without filling it — so quitting once with a review open left
every diff in that project with a blank old side, for good, and the `vim.diff`
that `<Leader>gw`/`<Leader>gk` run compared against nothing. `drop_uri_buffers`
closes and wipes them after a restore, and the save drops the ones no window is
showing; a window still on one belongs to something live, so the exit records it
and the next restore is what throws it away. This is core's business rather than
the git layer's — the rule is about URIs, not about Diffview, and `core` may not
name a plugin.

**A single directory argument means the project, not a directory to browse.**
`nv .` and `nv ~/code/thing` `cd` there, drop the argument and restore that
project's session. The directory *buffer* has to go with it: it is created before
`init.lua` is sourced, and the explorer claims it on the first `BufEnter` and
takes the window the session is about to restore into — so `setup()` wipes it,
which is also why that step runs from `setup()` and not from the `VimEnter`
autocommand. With no stored session the result is the ordinary empty start, the
dashboard rather than the explorer.

**An exit only overwrites a session it is responsible for.** Autosave requires
the session to be *attached* — restored or started clean, or claimed by an
explicit `:SessionSave`/`:SessionRestore` — and requires at least one listed
file-backed buffer to still exist. So `nv one-file.rs` in a project leaves the
stored layout alone, and so does closing a project buffer by buffer before `:q`.
Stdin and diff starts never attach, and `:SessionDelete` detaches, which is what
suppresses the save for that exit.

`<Leader>t` and `:Terminal` toggle one interactive shell in `core.pane`. It is a
normal pane occupant: `h` hides it without stopping the shell, `q` stops it, and
`<Esc><Esc>` leaves terminal mode. Native `:terminal` remains available when an
ordinary unmanaged terminal window is wanted.

## Debugging

nvim-dap lives in `lua/plugins/debug/`, a directory rather than a file because
lazy's `lsmod` is non-recursive: it enters a subdirectory only through its
`init.lua`, so the siblings there are never mistaken for plugin specs. The
directory name is kebab-case because it is discovered by walk; the files inside
are snake_case because they are `require`d by path.

```
plugins/debug/
  init.lua         the LazySpec, every key, and the config entry point
  session.lua      lifecycle, signs, stepping, stop, the <Leader>r provider
  breakpoints.lua  set/condition/logpoint/mute/clear, and persistence
  inspect.lua      eval float, borrowed K, watch prompt
  ui.lua           the dap-ui panel, the element floats, the REPL
  adapters.lua     codelldb, plus whatever the lang layer declared
  health.lua       :checkhealth plugins.debug
```

**Starting a session is a language's job, never the debug layer's.** A `Debug`
category action is the only way in, because `<Leader>r` is the only entry point a
language module gets. `<F5>` with no session open does not guess — it opens the
Debug actions for the current buffer. The debug layer's own provider is about a
debugger that is already loaded: continue, stop, attach to a process, the
breakpoint set.

**One adapter, one owner**, the same rule as the LSP. A language declares its
adapter through the `dap` key described above; rustaceanvim owns codelldb for
Rust the way it owns rust-analyzer, so `lang/rust` only tells it *which*
codelldb. `adapters.lua` registers plain `codelldb` for everything else, found
through `$CODELLDB`, `PATH` — which includes mason's `bin`, so `:MasonInstall
codelldb` answers here — or `~/.local/share/nvim-dap/codelldb` where `just
install-codelldb` puts it. When none of the three answers, the action stays
visible and says so.

**The UI is a left panel and nothing else.** `breakpoints .15 / stacks .20 /
scopes .40 / watches .25` at 55 columns, opened on attach or launch rather than
on the first stop, because the panel being there is how you know a debugger is.
Under 150 columns it is never built and `<Leader>du` gives the scopes float
instead; `dapui.setup` tears down every window it owns, so that decision is made
once and not revisited on a resize. dap-ui's own vertical resize is unusable —
`WindowLayout:resize` walks its windows with `pairs`, so each pane takes space
from a neighbour that may not have been sized yet and four panes come out as
roughly one. `size_panel()` sets the heights bottom upwards instead, and must
stay.

**The debugged program's own output is an occupant, not a stray window.** codelldb
asks for an integrated terminal through `runInTerminal`, and nvim-dap's default
answer is `belowright new` — a window nothing here manages, which is how the
output went missing the first time this was used for real. `terminal_win_cmd` is
a function instead: it hands nvim-dap a buffer already shown in the strip as
`program`. nvim-dap **pools** terminal buffers and reuses one without asking for a
window again, so a `TermOpen` autocommand re-adopts anything carrying nvim-dap's
`dap-type` buffer variable. Inspect → *Show the program's output* brings it back.

Reading that buffer the instant a process exits shows nothing: the pty has not been
drained yet. That is a test artefact, not a bug — do not "fix" it.

**Stopping is one key and it knows the difference between detach and kill.**
`dap.terminate` is asynchronous, so the panel comes down in `on_done` rather than
on the next line — calling `close()` immediately is why stopping did not always
stop. An `attach` session sits beside a process someone else started, so
`terminateDebuggee` follows `config.request` rather than defaulting to true.
There is no restart key: on an attach session a restart means re-attaching, which
is `<Leader>dq` and then `<Leader>r`, and one honest pair beats one key that
means two things.

At the default INFO level nvim-dap logs the adapter's lifecycle and nothing else,
so an empty log is not evidence that nothing went wrong. Two actions cover that:
Maintenance → *Trace the adapter protocol* sets TRACE and deletes the old log so
what you capture is only the next run, and Inspect → *Show the adapter log* opens
it in the strip. That pair is the first thing to reach for when a session behaves
in a way `:ActionsStatus` cannot explain.

**A session that ends says why.** `exited` / `terminated` / `stopped` / `detached`
each carry their own wording, and the program's exit code when the adapter sends
one, because a bare "session ended" reads as a crash — stepping past the end of
`main` exits the program like any other run, and the panel closing is that, not a
fault.

**Breakpoints outlive the session and the editor.** They are stored per project
under `stdpath("data")/dap/`, named with `vim.fs.slug(cwd)`, and restored when the
debugger loads — which is why the spec carries `event = "VeryLazy"` in a project
that has a store and stays key-loaded everywhere else. Muting is remembering the
set and sending an empty one, because DAP has no disabled breakpoint; clearing
while muted has to forget the muted set too, or the next unmute resurrects what
was thrown away.

**Every breakpoint change is pushed to the adapter by hand.** `dap.breakpoints.get`
drops a buffer from its result as soon as the last breakpoint in it is gone, and
`Session:set_breakpoints` sends nothing when handed an empty table, so "there are
none left anywhere" never reaches the adapter on its own: the signs disappear and
the program goes on stopping where they used to be. `sync()` names the emptied
buffers explicitly. Do not simplify it.

`K` is borrowed for runtime evaluation while a session is live and given back
with `mapset` *inside* the buffer it came from — `lsp.lua` installs its `K`
buffer-locally, so deleting ours would otherwise leave the buffer with no hover.

Deliberately not here: **inline values**. The always-visible scopes panel is the
answer to "what is this worth", and a virtual-text layer would duplicate it while
mis-attributing shadowed names. `nvim-dap-virtual-text` is one spec away if it is
ever missed. **Condition linting and REPL completion** are also left out; the old
config's `debug/condition.lua` and `debug/completion.lua` are reference material
for the day a silently-never-firing conditional breakpoint becomes annoying
enough.

## Git

Three plugins in `lua/plugins/git/`, and the division between them is the whole
design: **gitsigns** is the gutter and the hunk, **Diffview** is where changes
are *read*, **Neogit** is where the repository is *moved*. Anything that
changes a ref, the index outside a hunk, a stash or a remote is Neogit's, and
there is no second spelling for it here — Neogit's own status buffer is one
letter per action, and duplicating those under `<Leader>g` would be the
fragmentation this rewrite removed. snacks' git pickers and lazygit are both
deliberately unused: the three above are buffer-and-window plugins, which is
what makes the layer feel like the editor rather than a TUI in a float.

A directory rather than a file, for the same reason as `plugins/debug/`: lazy's
`lsmod` is non-recursive, so the siblings are only reachable through
`init.lua` and are never mistaken for specs.

```
plugins/git/
  init.lua       the three specs, every global key, the Diffview options
  signs.lua      gitsigns: signs, hunk nav, preview, stage, blame
  review.lua     the hold, the snapshot, the q prompt
  hud.lua        the winbar, conflict counting, resolution marks
  revert.lua     revert at four sizes, keep-these-lines, undo-a-formatter
  conflicts.lua  the merge keys
  nav.lua        walking changes and conflicts, including from the file panel
  goto.lua       gf, settling the review before it opens the file
  image.lua      the picture in the pane, where an image entry was blank
  status.lua     the branch and +~- counts in the statusline
  keys.lua       the legend along the bottom of a review
  health.lua     :checkhealth plugins.git
```

`status.lua` is the first user of `core.statusline.register`, which is what
that hook was built for: the branch comes from gitsigns' own
`b:gitsigns_status_dict`, so `core` still names no plugin.

### The review is a transaction

`<Leader>gd` opens a review in which **nothing reaches disk until you say so**.
Reverts apply to the buffer immediately — you see them, `u` undoes them — and
`q` asks Save, Discard or Cancel for the review as a whole. That is the point
of the layer: a revert you regret costs one keypress, not a lost afternoon.

**`'readonly'` is what holds a file back, and nothing else works.** An error
thrown from `BufWritePre` only aborts writes issued through the API — `:w`
typed on the command line prints the error and writes the file anyway. `:write`
refuses a readonly buffer itself, before any autocommand. Consequences, all
handled in `review.lua`:

- Neovim prints `W10: Warning: Changing a readonly file` on the first change to
  each held buffer, and a `FileChangedRO` handler explains it once per review.
  Diffview's own conflict actions surface it as `Error in command line`; only
  our own `diffget`/`diffput` are `silent`.
- **After that warning Neovim sleeps for about a second so it can be read**, once
  per buffer and only with a UI attached — which is why no amount of headless
  verification found it, and why the first `H`, `r` or `R` in every held file
  looked like a hang. Measured 1007.8 ms against 1.0 ms. So every mutation this
  layer makes goes through `review.mutate`, which drops `readonly` for the
  duration and puts it back before returning; re-arming does not re-arm the
  warning, because `b_did_warn` is already set. The hold is about `:write` and is
  unaffected. **A new key that changes a held buffer has to use it** — that is the
  whole reason it exists rather than each caller toggling the option. Its `defer`
  argument is for `conflict_choose_all`, which is `async.void` and can finish on a
  later turn.
- **`confirm = true` is set in `core/options.lua`, so a plain `:w` on a held
  buffer is a dialog rather than `E45`.** Answering yes writes it. That is a
  weaker barrier than the old config had, and it is survivable only because of
  the next point.
- A write that gets past the hold — `:w!`, or a confirmed `:w` — is *accounted
  for*: a `BufWritePost` handler re-arms `readonly`, re-baselines the snapshot
  so `q` no longer counts the file as pending, and says the rest of the review
  is still waiting. If the file still has conflict markers it says that instead.
- Anything asking "was this file writable?" must ask the snapshot, not the live
  option, which is why `M.writable` exists. The revert keys once read
  `vim.bo.readonly` directly and refused every file in a held review.

The snapshot does not carry `autosave` or `autoformat`. The Rust idle autosave
is suspended through `core.autosave` while a buffer is held and resumed when the
review releases it; any future automatic writer needs the same explicit hook or
a held file can reach disk behind the review's back. An agent is the same hazard
with nothing to suspend, since it writes from outside the editor; see The
assistant for what `<Leader>a` does about it.

`disk_state` is dev, inode, size and mtime to the nanosecond, because an
outside writer changing equally-sized text in the same second must still stop
the review from overwriting it. Every file is preflighted before the first one
is written, so a checkout or a pull mid-review stops the save instead of
half-applying it.

**Staging cannot take part of an in-memory transaction**, so it is blocked
while a review holds a buffer — both in Diffview's file panel (`-` `s` `S` `U`)
and in gitsigns, where `<Leader>gs` and the reset keys check
`review.holds(bufnr)` and explain rather than failing. The one exception is a
merge, which stages *on Save*, so writing and staging cannot come apart: git
counts a resolved-but-unstaged file as still unmerged.

### Reverting, at four sizes and two shapes

`r` is the change under the cursor, `R` the file, `<Leader>gl` the line,
visual `<Leader>gr` the selection — all of them Vim's own `do`/`dp`/`diffget`,
which means they are pending until `q`. They report when nothing happened,
because off a change those commands are silent and there is otherwise no
telling that from a key that did nothing.

The other shape is the formatter's: the file is now almost entirely churn and
the few lines worth keeping are the small part. `<Leader>gk` keeps a selection
and reverts every *other* change in the file; `<Leader>gw` reverts only what
did not alter the text. Ranged `:diffget` cannot express either — both need the
**complement** of a range, several disjoint hunks applied without the earlier
ones renumbering the later — so the hunks come from `vim.diff(…, {result_type =
"indices"})` and are applied bottom-up. The measured off-by-ones: a hunk with a
zero count on one side reports the line it sits *after* on that side, and `0`
means before the first line. A hunk the selection touches at all is kept whole,
because splitting one would claim a line-for-line correspondence that a reflow
has destroyed. Whitespace is compared by joining each side with a single space
and collapsing runs, so a call rewrapped across three lines compares equal while
`foo bar` and `foobar` do not.

### Merge conflicts

`diff3_horizontal` — OURS, RESULT, THEIRS — chosen over `diff4_mixed` so the
pane you edit keeps full height. BASE is therefore not on screen, which is what
`<Leader>cb` is for, and it is a **preview, not a take**. The key once did both —
it replaced the region when `merge.conflictStyle` was `diff3` and otherwise showed
the file — which made it mean two different things depending on a git setting.
Now it always reads stage 1 (`git show :1:`) into a **float**, because a new
window inside the layout is a window Diffview tries to fold into the diff, and
taking from it is `<CR>`: the same accumulating take the side panes have, so
there is no second spelling of "replace this region".

**The float is scoped to the conflict under the cursor**, since the whole ancestor
file from line 1 does not answer "what did *this* start as". The region's own
`ours` content is verbatim from stage 2, so it is located there by text — nearest
occurrence to the region's line, because a block can appear twice — and a
`vim.diff` of stage 1 against stage 2 maps that range back onto the ancestor,
which is then signed and centred. `theirs`/stage 3 is the fallback for a region
whose own side deleted everything. **The stages are read from git, not from the
OURS and THEIRS panes**: Diffview loads those lazily, and a pane that has not been
entered yet holds a single empty line, which is what made the first version of
this find nothing. `to_ancestor` inherits `revert.lua`'s off-by-ones — a hunk with
a zero count on one side reports the line it sits *after*. An add/add conflict has
no stage 1 and says so rather than opening an empty float.

`H`/`L`/`B`/`X` replace a whole region with one side, which is all Diffview
offers. `<CR>` works the other way: the selected lines are copied in **above**
`<<<<<<<` and the region is left standing, so several takes accumulate and `X`
— already "drop both sides" — ends the region. Lines are taken as *text* from
whichever buffer is focused, so the side panes work without mapping their line
numbers onto the file being written, and marker lines are filtered by line
number rather than by looking like markers: a row of `=======` is a heading in
Markdown and a separator only inside a region.

**Resolution marks are extmarks, not signs.** A resolved region has no markers
left, so without them there is nothing to navigate back to and nothing to
check. They carry `virt_text` plus `number_hl_group` for two measured reasons: a
diff background outranks `CursorLine`, an extmark `line_hl_group` and a
char-range `hl_group` at priority 300, so only the sign column, the line-number
highlight and virtual text survive on a changed line — and the sign column
already has git's own signs in it. Extmarks also move with later edits.
`gH`/`gL`/`gB` leave no marks: `conflict_choose_all` is asynchronous and the
positions are gone by the time it returns, and a whole-file take is one
decision that the counter already reports.

**A resolved file stops instead of advancing.** The last conflict going away is
the one moment the resolutions are on screen to be read, so the hud says how
many files are left and waits for `<Tab>`, which walks forward with wrapping —
the next file needing work can be one already walked past. Counting those files
reads the ones the review has not opened, so it happens when a file is opened or
finished and is cached in a buffer variable, never from the winbar, which is
evaluated on every redraw. For the same reason it looks for a loaded buffer **by
name** first: a file resolved earlier is still loaded but its layout has moved
on, and the copy on disk still has the markers.

**The finish shows the staged diff.** The merge panes compare the resolution to
each side, so nothing in the review has shown the merge as a change to your own
branch. "Save and finish" stages, reopens `DiffviewOpen --cached` labelled
`STAGED`, and hands the commit to Neogit only when *that* closes — scheduled,
because Diffview keeps one view per tab and the prompt runs while the merge view
is still open. Neogit's commit editor then shows the same diff under the
message, which is the escape hatch: `<C-c><C-k>` abandons the commit with the
resolutions still staged. It is offered only when nothing is unresolved,
including conflicted files the review never opened, because `git merge
--continue` counts those too.

### Leaving a review at a file

Diffview's `gf`, `<C-w><C-f>` and `<C-w>gf` switch tabs and open the file with
the review still standing behind them, walking straight past the hold on that
exact buffer — you land in your own file, type, and `:w` argues with you. All
three are **taken over** rather than left beside new keys, so the version that
bypasses the transaction is not reachable by accident. `goto.lua` settles the
review through the ordinary `q` path first and opens the file only if that
finished. Everything the jump needs — the entry, its path, the cursor — is read
**before** the close, because all of it is destroyed with the view; the file is
reached by **buffer** whenever it is still loaded, since `:edit` would re-read
from disk and throw away what Save or Discard just settled; the line comes from
the layout's main window, which is the working side; and a merge refuses on a
file that still has markers, because saving would not write it and the jump
would open the copy from disk. "Save and finish" wants this tab, so the jump
stands down rather than racing it.

### Images in a review

An image entry showed **two blank panes**, whatever its status. Diffview's
`vcs/file.lua` runs its binary check *before* the working-tree branch, so an
image — added, modified or deleted — was handed `File._get_null_buffer()`, one
shared empty buffer that both panes point at. snacks never saw the file, and
neither did `:edit`.

`image.lua` gets there first. `File:is_valid()` is `self.bufnr and
nvim_buf_is_valid(self.bufnr)`, and `create_buffer` short-circuits on it before
it asks whether the file is binary, so assigning `file.bufnr` **is** the whole
intervention. It happens on `file_open_pre`, which fires in `DiffView:_set_file`
before `use_entry()` claims the windows. That event reaches the *view's* emitter
and not the `hooks` table, so `view_opened` is what registers the listener — the
same `view.emitter:on(…)` shape Diffview's own `File:post_buf_created` uses.

Everything after that is Diffview's: `Window.open_file` sets the buffer and
*then* calls `attach_buffer`, so `q`, `<Tab>`, `gf`, `r` and the winbar land on
these buffers with nothing re-applied. A nulled side is left alone, so a deleted
image is picture-and-blank and a modified one is the two versions side by side.

The source is the file on disk for the working tree, and for any other revision
a blob extracted into `stdpath("cache")/diffview-images`, named by its **sha** so
an index entry cannot go stale. `adapter:show` is not used — it returns lines,
and a blob has to stay bytes. `cat-file --batch-check` answers the sha and the
size in one process, which is what the 32 MB guard reads. The buffers are
scratch, tracked per view and wiped on `view_closed`: that keeps `review.track`
off them, since `is_file_buffer` rejects a `nofile` buffer, and keeps a
working-tree image out of the session.

Nothing here asks `supports_terminal`. A terminal that cannot draw gets snacks'
own note naming the file, which beats a blank; `health.lua` is where that is
reported, along with ImageMagick for the formats that need converting.

This reaches into `file.bufnr` and `file.binary`, two of Diffview's own fields.
That is the bet, and the lockfile pin is what makes it safe — if an update moves
the `is_valid` short-circuit, images go blank again rather than breaking
anything else.

### The legend, and the rest

`?` toggles a one-row float above the statusline listing the keys for the mode
you are in — diff, merge, or the staged finish. A float rather than a window,
because a real window there is one Diffview folds into the layout; entries drop
from the end as the screen narrows, so what survives is the half that moves you
around. It is closed on `VimLeavePre`: a float stored in a session comes back as
an ordinary window in the wrong place.

`enhanced_diff_hl` is **off**. It exists to highlight the changed words inside a
changed line, and `diffopt` already carries `inline:char` on this nightly, which
is the same thing done natively. `linematch:40`, `indent-heuristic` and
`internal` are also defaults here — `health.lua` checks they are still present
rather than setting them, since a local override is the only way they go
missing.

The file panel is left, 35 columns, tree, with `flatten_dirs` and
`folder_statuses = "only_folded"`, because a Rust or Unity tree is deep and
mostly single-child directories. `winbar_info` is off in all three layouts: the
hud is the single writer of that row, the same rule as one adapter, one owner.

**Diffview deletes every buffer-local keymap it set when it detaches a file**,
and two of them — `<Leader>gr` and `<Leader>gR` — are keys gitsigns had already
put on that buffer. So a file you had reviewed once came back with no reset
keys at all for the rest of the session. `signs.remap()` re-applies them from
the `view_closed` hook, `vim.schedule`d because the detach has not happened yet
when the hook runs. Any *new* buffer-local key that collides with one of
Diffview's `view` maps inherits this problem and has to be re-applied there too.

A review lives in its own tabpage, so a failing task **will** open `core.pane`
inside it and take height from the panes. That is deliberate and unsuppressed —
the contract that a failing build shows itself outranks the layout — and if it
turns out to be annoying, the fix is to route the pane to the previous
tabpage, not to silence it.

Two commands, both about a review that went sideways: `:DiffviewClose` is
replaced so a typed close gets the same prompt as `q`, and `:ReviewFinish`
settles a review whose tab was closed directly. There are no other `:Git*`
commands.

Deliberately not ported: the old `git_stash.lua` (Neogit owns stashing),
`diff_keys`' persistence of the legend's hidden state, and gitsigns'
`<Leader>gd` buffer-local override, which existed only to beat an AstroNvim
mapping that no longer exists. Kept from the old stack because each one encodes
a bug already paid for: the `'readonly'` hold, the bottom-up hunk application,
the extmark marks, the `gf` takeover, and the inline-preview `tabstop` fixup —
gitsigns builds that float with `nvim_create_buf` and copies only `filetype`,
while editorconfig sets indent width per file off `BufReadPost`, which a scratch
buffer never fires, so every old line lands `(difference × depth)` columns off.

## The assistant

`lua/plugins/assistant/` is Claude Code, on the `<Leader>a` prefix the keys table
has always reserved. It is `coder/claudecode.nvim` and nothing else: the plugin
speaks Anthropic's IDE websocket protocol, so the `claude` CLI running in a
snacks terminal knows which buffer and selection you are on, `@`-mentions resolve
to real paths, and its edits arrive as a diff with accept and deny. There is no
Node runtime, no bridge process and no stored token — it rides the CLI's own
login. A directory rather than a file for the same reason as `plugins/debug/` and
`plugins/git/`: lazy's `lsmod` is non-recursive, so `health.lua` beside it is
never mistaken for a spec.

**Eight keys, and two of them are the same key.** `<Leader>as` sends the visual
selection in an ordinary buffer and adds the files under the cursor in a
`snacks_picker_list` one, because `ClaudeCodeSend` dispatches on filetype itself.
The old config bound a second, buffer-local key from a `FileType` autocommand for
that; it is not needed, and a plugin spec writing global keymaps into other
people's buffers is what this rewrite removes. `<Leader>am` (select model) and
`<Leader>aS` (connection status) were dropped: `/model` is one word typed in the
terminal that is already in front of you, and the status is
`:checkhealth claudecode`.

**Claude writes to disk; a review holds its buffers in memory.** This is the
hazard the Git section warns about under a different name — *"whoever adds a
formatter or an autosave has to suspend it here"* — except an agent writes from
outside the editor, so there is nothing to suspend. The decision is to **warn
once per review and allow it**: `<Leader>a` keys that can reach the agent call
`plugins.git.review.held()` first and say how many files are being held off disk.
Once, not every press — the choice is yours to make and restating it is noise.
The call is a `pcall`, the same shape and for the same reason as `roslyn.lua`
reaching for the Unity root: deleting `lua/plugins/git` must leave this working.
`review.held()` exists for this caller alone; `health.lua` checks it still
answers, because a `pcall` that starts failing goes quiet rather than loud.

**The terminal is a right split, not `core.pane`.** The strip is last-writer-wins
by design, so a chat you keep open all day would be evicted by every failing
build. A side panel claims nothing `core.pane` owns. `provider` is stated as
`snacks` rather than left at `auto`, which probes with `require` and would pick
up whatever else happens to be installed — the same rule as Neogit's
`integrations`.

Deliberately not here yet: the **explain and discuss** half — a read-only
`claude -p` into a float, with `--restricted` on the deep variant so it can chase
a call into the next file, and a generated `--session-id` so "discuss this" can
resume that exact conversation in the terminal. The treesitter context in the old
`user/ai_explain.lua` is the part worth keeping. It needs no plugin, which is
most of why it can wait. Also not here: **inline completion**, which is a
separate plugin and collides with blink's `<C-j>`/`<C-k>`/`<C-l>` scheme.

## Diagnostics

`core/diagnostics.lua` is the one `vim.diagnostic.config` call, made from
`init.lua` before anything can report a diagnostic. It is core because it names
no plugin and no language: a server-specific opinion is server settings, and a
picker over the list is snacks' business.

**Errors render inline, and only on the cursor's line.** `virtual_lines =
{ current_line = true }` with `virtual_text = false`. The reason is message
length: rustc and roslyn both write several lines with a caret diagram, which
end-of-line virtual text truncates to uselessness and full-file virtual lines
turn into a file where the code is a minority of the screen. Cursor-scoped
expansion is the middle that keeps both. The update is native and happens on
`CursorHold`, so it is paced by `'updatetime'` — 250 here. There is no
`CursorMoved` autocommand to add; `vim/diagnostic/_handlers.lua` owns it.

**They also render while you type, and that costs two things.**
`update_in_insert` is on, because with it off `_display.lua` defers every
publish to `InsertLeave` and nothing at all appears in insert mode. That alone
is not enough: the `current_line` handler renders from `CursorHold`, which has
no insert-mode counterpart in `on_line_hold`, so the block stays under the line
it was last published for while the cursor walks away from it — measured, and
the reason `core_diagnostics` is a `CursorMovedI` autocommand calling
`diagnostics.on_insert_move`. It re-shows only when the *line* changed, not on
every keystroke, and only while the handler is cursor-scoped: widened to every
line by `<Leader>uv` the publish already draws them all, and a re-show per line
would be a whole-file render for nothing.

`<Leader>uv` widens the same handler to every line for the times the whole
file's errors are the question, and says which mode it landed in. It is a
scope toggle, not an on/off — hiding diagnostics entirely is still
`<Leader>ud`.

Signs carry the same two glyphs the statusline counts with, so the gutter and
the status row agree. `severity_sort` is on.

## Completion and inlay hints

Completion is **blink.cmp**, and it is explicitly **temporary**. It is the one
plugin here that exists to work around a bug rather than to add capability, so
it carries a removal note at the top of `plugins/completion.lua`. When native
`'autocomplete'` works, delete that file and re-enable the option.

The native path underneath still works and is the fallback: `'complete'` is
`.,o,w,b` so `<C-x><C-o>` and `<C-n>` search the buffer, the LSP (`o` is
omnifunc, which 0.13 points at the server on attach) and other buffers
together, with `completeopt` at `menu,menuone,noselect,popup,fuzzy`. Leave
both set — they cost nothing and they are what the config returns to.

**`'autocomplete'` is off, deliberately.** 0.13 added it, and on this nightly
it corrupts the buffer whenever the LSP is a `'complete'` source: `CompleteDone`
fires with reason `accept` while `complete_info().selected` is `-1`, and the
item's text edit is applied mid-typing. Typing `l`, `e`, `t` in a Rust buffer
produces `include_bytes!(let)`. Bisected: present with `fuzzy` on or off, at
`autocompletedelay` 75 and 400, with `preselect` removed, and with
`commit_characters = false`; absent when `o` is dropped from `'complete'`, and
absent when `'autocomplete'` is off. It is the `'autocomplete'` + LSP-omnifunc
combination, not our settings. Re-test on a newer nightly before re-enabling,
and reproduce with `l`,`e`,`t` in a Rust buffer rather than trusting the option
list.

Note the coupling: `menu`/`menuone`/`noselect` are *ignored* when
`'autocomplete'` is on but *required* for the popup to appear when it is off.
Whoever flips that option has to fix `completeopt` in the same commit.

`vim.lsp.completion.enable(..., { autotrigger = true })` was tried as the
alternative auto-popup path and produced no menu at all. Not understood; it is
not a substitute yet.

What native does not do is **frecency** — it never learns which candidates you
accept. That, plus a working auto-popup, is what would justify blink.cmp.

Inlay hints are **on by default**, enabled from the `core_inlay_hints`
`LspAttach` autocommand, guarded on the client advertising
`textDocument/inlayHint`. `<Leader>uh` toggles them. Per-server tuning is
server settings, not core's business: rust-analyzer's live in
`lang/rust/init.lua`, trimmed to type, parameter and chaining hints with
closing-brace and lifetime-elision hints off, because those two are what turn
a dense file into noise.

Roslyn's live in `lang/csharp/roslyn.lua` and are **two gates and their
children**, which is the part worth knowing:
`csharp_enable_inlay_hints_for_types` and
`dotnet_enable_inlay_hints_for_parameters` each default to false and each
silently discards the sub-options underneath it. Setting only the children —
which this config did — renders no type hints at all and only literal
parameter hints, so `var thing = GetThing()` was bare. Both gates are open now
and every child under them is stated.

The suppression rule is **exact name match and nothing wider**.
`dotnet_suppress_inlay_hints_for_parameters_that_match_argument_name` is on, so
`SetColor(color)` is bare; the other two are written as `false` rather than
left out, because they are a decision. `..._differ_only_by_suffix` would drop
the hint from `SomeFunction(nameText, 30)` and `..._match_method_intent` from
`SetColor(GetName())`, and both of those are the cases the hints exist for.
Roslyn does not read `GetName()` as matching a `name` parameter, so
`SomeFunction(GetName(), 30)` keeps its `name:` — which is the whole point.

These reach the server at `initialize`, so changing one needs a restart rather
than `<Leader>uh`, and Unity inherits all of it: `unity` declares no `lsp` key
and `csharp` owns roslyn_ls for those buffers.

Code lens is **on by default and global**, unlike the per-buffer inlay hints
above. `core/codelens.lua` is the only writer: it sets the global marker at
startup and `<Leader>uc` flips it for every buffer at once. There is no
`LspAttach` hook for it — `vim.lsp.codelens.enable` with no `bufnr` filter sets
`vim.g._lsp_enabled_codelens`, which is what a client consults as it attaches, so
a buffer opened later inherits the state without one.

A **review suspends it**, because a lens takes a screen row and the two sides of
a diff then stop lining up. `plugins/git/init.lua`'s `view_enter`/`view_leave`
hooks are what do it, so the suspension follows the review's *tabpage* rather
than its lifetime and a file open in another tab keeps its lenses. Suspension is
by name (`core.codelens.suspend`/`resume`), and an explicit `<Leader>uc` clears
every suspension — a key the user pressed outranks one the config suspended,
which is what makes the toggle work inside a review rather than reporting a
state that is not on screen.

0.13's `vim.lsp.codelens.enable` is the `vim.lsp._capability` machinery that
`inlay_hint.enable` uses, so refresh is viewport-driven and resolution is on
demand — the `CursorHold`/`InsertLeave` refresh autocommand every guide tells
you to write is obsolete here. Do not add one. Running a lens is `grx`, a 0.13
default, which is one more reason not to bind bare `gr`.

There is **one** retry, and it is not a refresh loop. A `codeLens/resolve` that
the server answers `-32801 ContentModified` — which rust-analyzer does for the
first lenses in a file while it is still loading the workspace — is logged and
dropped by `codelens.lua`, and the row has already been marked current, so
nothing ever asks again: the lens is a blank placeholder until an edit bumps the
document version. That is the "the lens only appears once I start typing"
symptom. `core_codelens` therefore also watches `LspProgress` with `pattern =
"end"` and, **only** for a buffer that still holds an unresolved lens, toggles
`vim.lsp.codelens.enable` off and on for it, which is the supported way to force
a fresh request. The unresolved check is what keeps this from being the refresh
autocommand the paragraph above forbids: it fires for the server that answered
too early and for nothing else. It asks `core.codelens` first, because a
per-buffer re-enable would otherwise put lenses back in a review the tabpage
hook had just taken them out of.

What the lenses are for is **counts**: references and implementations, the
questions `grr`/`gri` answer but that a count answers without leaving the line.
rust-analyzer's `lens.run`/`lens.debug` are therefore **off**, but only as a
matter of taste: `<Leader>r` carries both, and a lens above every `fn` costs a
screen line each. They work if turned on — rustaceanvim's `ftplugin/rust.lua`
registers `rust-analyzer.runSingle` and routes it through `runnables.run_command`,
which is the executor slot that already lands in `core.task`.

What does need saying is `rust-analyzer.showReferences`: rustaceanvim's handler
for it is `vim.lsp.buf.implementation()` regardless of which lens was run, so a
"3 references" lens navigates to implementations and bypasses the picker. The
lens carries its own locations in `arguments[3]`, so `lang/rust/lens.lua`
replaces the handler and shows those, `focus = "list"`, like the rest of the `gr`
family. It installs from a `FileType rust` autocommand inside a `vim.schedule`,
because rustaceanvim registers its version from an ftplugin on that same event —
scheduling is what puts the override after it instead of under it.

Roslyn's `dotnet_enable_references_code_lens` is on with the caveat written
beside it: `background_analysis` is scoped to `openFiles`, and a reference count
is only as good as the analysis behind it, so a Unity solution will undercount.
That is the honest trade against whole-solution analysis never settling.

Deliberately not built yet: **per-symbol suppression** — hiding the lens or the
hints for one function, one class, or one parameter, stored per project. There
is no seam for it in either API (`enable` filters by buffer and client, nothing
finer), and the two features are not equally cooperative if it is ever wanted:
`inlay_hint.lua` requests with a `nil` handler, so
`vim.lsp.handlers['textDocument/inlayHint']` is a documented place to filter,
while `codelens.lua` passes its own closure and never consults the handler
table. Filtering lenses means patching a private internal or rendering them
ourselves. `plugins/debug/breakpoints.lua` is the precedent for the per-project
store if that day comes.

LSP progress is shown in the global statusline. While idle it lists the clients
attached to the current buffer; while a client is working its current progress
replaces that list. Routine indexing does not produce notifications.

The statusline is native and lives in `core/statusline.lua`. `cmdheight=0`
lets `:`, `/`, `?`, messages and prompts temporarily cover that same final row.
Plugin-owned information is added with `core.statusline.register`, which is how
`plugins/git/status.lua` places the branch and `+`/`~`/`-` counts beside the
filename without making `core` depend on a plugin. The path is `pathshorten`d,
so every directory is one letter and only the filename is written out: a Unity
or Rust tree is deep enough that the untruncated path crowded out everything to
its right, and `%<` dropping the *front* of it took the part that says which
project you are in. A component's text is escaped
unless it sets `raw`, which is what lets the git counts carry their own
highlight groups; a `raw` component is responsible for its own `%%`.

## Macros

`core/macros.lua` is the whole of it: `q<letter>` otherwise says nothing, and a
recording left running is how a stray `j` ends up in register `q`. A recording
puts  and the register beside the mode block, from `RecordingEnter` and
`RecordingLeave` in `core/autocmds.lua`. `reg_recording()` still answers *while*
`RecordingLeave` runs, so the redraw that clears the indicator is scheduled
rather than made inside the event.

`<Leader>q` and `:Macros` list the non-empty `a`-`z` registers with their
contents through `vim.fn.keytrans`, so `<Esc>` and `<CR>` read as keys rather
than as control characters, and `<CR>` runs the chosen one. Nothing distinguishes
a macro from a yank -- they are the same register -- so the list hides neither:
the ones recorded in this session carry a mark and sort first, most recent
first, and the rest follow in register order. `RecordingLeave` is what records
that, keyed by the lowercase register, because `qA` appends to `a`.

It is `vim.ui.select` rather than a picker of its own, which snacks owns, so
`core` still names no plugin.

## Keys

Prefixes in use: `<Leader>a` assistants, `<Leader>f` find, `<Leader>s` search, `<Leader>u` toggles,
`<Leader>w` windows, `<Leader>b` buffers, `<Leader>r`/`<Leader>R` actions,
`<Leader>d` the debugger, `<Leader>t` the terminal, `<Leader>q` the macro list.
`<Leader>m`/`<Leader>M` and
`<Leader>1`–`<Leader>4`
are grapple. `<Leader>g` is git.

`<Leader>g` carries two layers that mean the same thing by different mechanisms,
which is deliberate: outside a review `<Leader>gr`/`gR` are gitsigns resetting
against the index, and inside one they are a **pending** revert that `q` decides
the fate of. Both roll back; the scope rule (lower is the hunk, upper is the
file) is the same in both. The in-review spellings are Diffview layout keymaps
and are therefore buffer-local to the diff, which is what keeps them from
leaking into ordinary buffers. `<Leader>cb` is the one key outside the documented
prefixes: it exists only in the `diff3`/`diff4` merge layouts, so it claims no
global prefix. `]g`/`[g` walk hunks and fall back to the native `]c`/`[c` inside
a real diff.

`<F5>` `<F10>` `<F11>` `<F12>` are continue and the three steps, duplicating
`<Leader>dc` `dn` `di` `do`. That is the second deliberate duplicate in this
config, on the same reasoning as `gd` for `grd`: the convention is worth more
than the uniqueness, and stepping is the one debug action pressed dozens of times
a minute. Every *other* debug key lives under `<Leader>d` and has exactly one
spelling. `<F1>` is the cheatsheet and is not part of the family.

Constraints that 0.13 and this layout impose, most of which already cost a
mapping once:

- `Q` is |multicursor|, not register replay. `<C-L>` clears cursors by default,
  but `<C-h>`/`<C-j>`/`<C-k>`/`<C-l>` are window navigation here and that takes
  precedence. Clearing moved to `<Esc>`, which wipes the `nvim.multicursor`
  namespace — the documented equivalent. If `<Esc>` is ever rebound, the clear
  has to go somewhere else first.
- `grn` `gra` `grr` `gri` `grt` `grx` are built-in LSP defaults. Binding bare
  `gr` makes all six wait out `timeoutlen`. Do not bind `gr`.
- The whole LSP navigation family lives on the `gr` prefix, including `grd` for
  definition, which 0.13 has no default for — vanilla `gd` is local
  declaration, not LSP. One prefix, one shape. `gd` is kept as an alias for
  `grd` because it is the cross-editor convention; it is the single deliberate
  duplicate in this config.
- `grd` `grr` `gri` `grt` are overridden to run the snacks picker rather than
  filling quickfix, because they all answer "which of these locations did you
  mean". `grn` `gra` `grx` are left alone — they act on the symbol and produce
  no location list. Overriding those would be churn.
- These are the only overridden defaults, and they are set buffer-local on
  `LspAttach`, so the global defaults survive untouched for any buffer without
  a client.
- A Danish layout needs AltGr for `|` and `\`, so anything reachable only
  through those gets a leader alternative. `æ ø å` map to `[ ] $` and their
  shifted forms to `{ } ^`, in all of normal, visual and operator-pending.
- **`j`/`k` move in every list.** In the snacks pickers that is plain normal
  mode (hence `focus = "list"`), and `<CR>` confirms — `l` is *not* bound there
  and is still a motion. In the completion menu the same shape is
  `<C-j>`/`<C-k>` with `<C-l>` to accept, because insert mode has no bare
  `j`/`k` to spare. Keep any new list UI on `j`/`k`.
- The `<Leader>r` menu starts in insert mode, so it follows the completion-menu
  shape instead: `<C-j>`/`<C-k>` are snacks' own defaults and still move, with
  `<Tab>`/`<S-Tab>` and the arrow keys added, and `<CR>` confirms. `<Esc>` is
  rebound to cancel in insert mode too: snacks' default cancels from normal mode
  only, so a prompt-focused menu would otherwise take two presses to dismiss
  where every other list here takes one.
- Insert-mode `<CR>` and `<BS>` belong to mini.pairs, which takes them only if
  nothing else has. Binding either one means reproducing `MiniPairs.cr()` and
  `MiniPairs.bs()` inside the new mapping.
- The scheme stops at three keys on purpose. `<C-h>` is backspace in insert
  mode and must not be bound. `<C-l>` is safe: there is no `i_CTRL-L`, only
  meanings inside the native completion machinery that blink replaces.
- blink's `<C-y>` default is unbound rather than left as an alias, which keeps
  one accept key and restores `i_CTRL-Y` (insert the character above).
  `<C-k>` shadows digraphs (`i_CTRL-K`) only while the menu is open; blink
  falls back to the built-in otherwise.
- The grapple menu is the one place even `j`/`k` are not the whole story. It is
  a real,
  editable buffer — reordering tags is `dd`/`p` and the new order commits when
  the window closes — so `l` stays a motion and `<CR>` selects. Digits `1`–`9`
  are quick-select there, which means **counts do not work in that window**:
  `3G` selects tag 3 and closes rather than moving to line 3.
- The debugger keeps the `j`/`k` rule: `<Leader>dj`/`<Leader>dk` walk the stack
  frames, the dap-ui panes are ordinary buffers where `j`/`k` and `<CR>` already
  work, and the bottom strip cycles its occupants on `<Tab>`.

`timeoutlen` is 1000 while key hints are off. It was 400 globally, which
silently aborted `<Leader>` if you paused to think. Enabling which-key changes
it to 300 while the popup is available and restores the previous value when
the helper is disabled.

Before adding a mapping, check it against the live set rather than the source:

```
:lua for _, m in ipairs(vim.api.nvim_get_keymap("n")) do print(m.lhs) end
```

## `lua/user` — per-device

Intended to become its own git repository, added here as a submodule, so every
machine can link the same fine-tunings while keeping genuinely local ones
local. Consequences that the code must honour:

- `lua/user` may be **absent or empty** — on a fresh clone without
  `--recurse-submodules`, or on a machine that has not run device setup. The
  config must start normally in that case, not error.
- Nothing outside `lua/user` may `require` anything inside it.
- It is loaded last and may override any earlier layer.

`init.lua` loads `lua/user/init.lua` when it exists and reports an error without
preventing the rest of the config from starting. The checked-in example enables
key hints on startup with `require("plugins.key-hints.control").enable()`.

What belongs here: machine-specific paths, per-machine tool locations,
GPU/font/theme preferences, work-vs-home differences. What does not: anything
that would be correct on every machine — that belongs in `core`, `plugins` or
`lang`.

## Style

Lua formatting is enforced by `stylua` using the repository-root
`.stylua.toml`: 120 columns, 2-space indent, double quotes preferred, no
parentheses on single-argument string/table calls, simple statements collapsed.
Lint with `selene` against the repository-root `selene.toml`. Neither is
optional; run both before considering a change finished.

Naming: kebab-case filenames in `plugins/` and `lang/`, because those are
discovered by directory walk and never `require`d by name. snake_case in
`core/` and `user/`, because those are `require`d as module paths.

### Comments

**Write as few comments as possible.** This is a deliberate decision by the
owner of this config, not a style preference to be negotiated or softened. The
default for any new line of Lua is no comment at all.

Do not write:

- comments that restate the code (`-- set the tab width`)
- section banners, file headers, dividers, `-- luacheck:`-style decoration
- module summaries at the top of a file
- notes about what a function does — the name does that
- TODOs, changelog entries, or anything addressed to a future reader in general

A comment is justified only when the code cannot carry the information and its
absence would cause someone to break the line. In practice that is almost
always one of two things: a non-obvious external constraint, or a previous
approach that failed and would otherwise be reintroduced. One sentence, placed
directly above the line it defends.

LuaCATS annotations (`---@class`, `---@param`, `---@type`, `---@field`) are not
comments for this purpose. They are type information that lua_ls consumes, and
they are encouraged — they are the intended replacement for descriptive prose.
Keep them to types; do not smuggle explanation into them.

Naming and structure carry the explanation instead. If a block needs a comment
to be followable, extract it into a named local function and delete the
comment. That refactor is the expected response to the urge to explain.

The mechanical budget is **comments must not exceed 10% of code lines**,
excluding LuaCATS annotation lines. The budget is a ceiling, not a target;
files at 0% are normal and correct.

### Error handling

Fail loudly at startup for anything that makes the config wrong (see the 0.13
guard). Fail softly and explain for anything the user can act on — a missing
`cargo`, an unreachable Unity editor — via `vim.notify` with a `title`, or via
the `available` string on an action.

## Verification

`just check` runs the same gates the old config used, scoped to this directory:
`luac -p` on every file, the comment budget, `stylua --check`, `selene`, and a
headless smoke start that must reach a known marker with no `Error detected` or
stack traceback in the output. A change is not finished until it passes.

`:checkhealth` is expected to be clean. Assumptions this config owns — external
tools, paths, versions — get a health check rather than a comment.

The user loader tolerates `lua/user` being absent.

`stylua` and `selene` are not installed on every machine; `check.sh` reports SKIP
rather than failing, which means a SKIP line is a gate that did **not** run. Do
not read it as a pass.

## Porting from the old config

The old config is `../` (AstroNvim-based, ~18k lines of Lua across 133 files).
It is a **source of ideas and working code, not a target to reproduce**. The
default answer for any given module is "do not port it"; porting is the
exception, justified per module.

- **Done**: the context/action registry → `lua/core/actions.lua`; `danish-keys`
  → `lua/core/keymaps.lua`; `utf8-guard` → `lua/core/utf8_guard.lua`.
- **Done**: the debugger, as `lua/plugins/debug/` — rebuilt rather than ported,
  though `debug.lua`'s stop semantics, `breakpoints.lua`'s adapter sync and
  `ui.lua`'s panel sizing came across because each one encodes a bug already paid
  for. Deliberately left behind: `condition.lua`, `completion.lua`, `names.lua`
  and `repl.lua`. See Debugging above.
- **Rebuild, do not port**: the task/execution layer. The old stack (Overseer
  plus `task_output`, `task_pty`, `task_queue`, `workbench/tasks`, the templates
  and components) is reference material for behaviour, not code to move. It is
  done — see Execution above.
- **Done**: git, as `lua/plugins/git/`, rebuilt from the old stack
  (`diff_review`, `diff_hud`, `diff_keys`, `diff_goto`, `diff_revert`,
  `git_stash`, `plugins/git.lua`, `plugins/neogit.lua`) with the
  `docs/decisions/diff-review.md` findings moved into the Git section above,
  which is now the record. snacks' git pickers and lazygit are deliberately
  **not** used; its git keymaps were removed for this reason. Deliberately left
  behind: `git_stash.lua`, since Neogit owns stashing.
- **Done**: Rust, as `lua/lang/rust/`. rustaceanvim owns the rust-analyzer
  client, so the module has no `lsp` key — a second client from `vim.lsp.enable`
  would fight it. All three rustaceanvim executor slots route into `core.task`.
  Native rust-analyzer diagnostics see the unsaved buffer. After 800 ms without
  another edit, `core.autosave` writes an ordinary Rust file so check-on-save can
  run `cargo check`; Clippy remains the explicit *Lint with clippy* action.
  Deliberately left behind: `watch.lua` (374 lines, continuous build) and
  `dependencies.lua` (490 lines, crate search UI) are deferred until missed;
  `diagnostics.lua` and `project.lua` are dropped outright, since both exist
  only to reconcile bacon-ls against rust-analyzer and there is no bacon-ls
  here. Debugging is rustaceanvim's `debuggables`, wired to the codelldb that
  `adapters.lua` finds; `<Leader>r` carries it under Debug, cursor target and
  `debuggables last`. Those two always launch with an **empty argv**, which is
  why a third action, *Debug a binary with arguments*, builds through `core.task`
  and calls `dap.run` itself after a prompt: a binary that parses arguments exits
  inside the parse when it gets none — clap prints its usage and exits 2 — so
  stepping over that line ends the session and looks exactly like a crash. The
  prompt remembers its last answer per buffer, and the action needs only cargo and
  codelldb, not an attached rust-analyzer, because it does the build and the launch
  itself. `cargo.allFeatures` was dropped: it expands the feature graph so
  everything is indexed under every combination, which costs startup on a real
  workspace for features you usually do not build.
- **Done, natively**: `lsp_progress` needs no port. `core/statusline.lua`
  records `LspProgress` events and redraws the line. `vim.lsp.status()` is not
  used because it *consumes* its messages; it is a stream rather than the state
  the statusline needs on every redraw.
- **Done**: C# and Unity, as `lua/lang/csharp/` and `lua/lang/unity/`. All three
  phases, including tests, `.meta` handling and the editor and Android attach
  paths. See the section below for what each one encodes.
- **Done**: the assistant, as `lua/plugins/assistant/`. `claude.lua` came across
  as the one spec, trimmed by two keymaps and one autocommand. Deliberately left
  behind: `copilot.lua` and `blink-cmp-copilot` (inline completion is a separate
  question, and blink's keys are already spoken for), and `ai-explain.lua` with
  its CopilotChat dependency — the explain path is deferred rather than dropped,
  and when it lands it goes through the same `claude` CLI rather than a second
  vendor. `user/ai_explain.lua`'s treesitter context and `user/ai_review.lua`'s
  three prompts are the reference material for that day. The justfile's
  `install-codecompanion-agents` and `store-codecompanion-claude-token` were
  deleted with it: they pinned an ACP bridge and a Node 22 runtime for a plugin
  that was never added, and the keyring script they installed never existed.
- **Port on demand**: Python, C++, notebooks, inlay hints, hover, and the two
  deferred Rust modules. Port one when it is first missed, rewritten to the
  contracts above rather than copied.
- **Let die**: everything AstroNvim-shaped (`astrocore`, `astrolsp`, `astroui`,
  `community.lua`, `lazy_setup.lua`, `polish.lua`), the compatibility shims in
  `lua/user/compat/`, and `deprecations.lua`. Check `lsp_progress` and
  `lsp_file_events` against 0.13 natives before porting a line of either.
- **Done**: `cheatsheet` → `lua/core/cheatsheet.lua`. This reverses an earlier
  decision to let it die in favour of `<Leader>sk`; the keymap picker lists
  every mapping but teaches none of the native workflows, which is most of what
  the page is for.

Prefer a 0.13 built-in over porting: `textDocument/foldingRange` covers LSP
folding, `vim.net.request()` covers the old `http` provider, `vim.async` covers
async plumbing, `vim.fs.mkdir`/`slug` cover the path helpers, and `'autoread'`
now uses real filesystem watchers.

Check what a built-in actually does before retiring a plugin for it.
`vim.ui.img` is a `set`/`get`/`del` backend taking raw PNG bytes at a row and
column; it does **not** render images in a buffer. `snacks.image` stays for
that — it does the detection, the conversion of non-PNG formats through
ImageMagick, and the placement. Removing it once already broke image rendering.

When porting, rewrite to the new contract. Copying a file across and leaving it
shaped like AstroNvim reintroduces exactly the inconsistency this rewrite
exists to remove.

## C# and Unity

Two modules, not one. `lua/lang/csharp/` is C# on its own and must keep working
with `lua/lang/unity/` deleted; `lua/lang/unity/` is the editor, the project
layout and the tooling around it.

**One server, one owner.** `csharp` declares `roslyn_ls`; `unity` has no `lsp`
key. `roslyn.lua`'s `root_dir` `pcall`s `lang.unity.project` and prefers the
Unity root when there is one, because Unity's `.sln` sits above `Assets/` and
the solution is what makes cross-assembly navigation work. That `pcall` is the
only reference between the two modules and it is the reason it is a `pcall`.

The server binary is found through `$ROSLYN_LS` or `roslyn-language-server` on
`PATH`, and when neither answers the `lsp` key is **absent** rather than
declared — `vim.lsp.enable` on a missing `cmd` warns at every matching
`FileType` forever. `:ActionsStatus` says which of the two was used.
`:MasonInstall roslyn-language-server` is the normal way to satisfy the second;
the env override stays for a copy that came from somewhere else, such as the
one inside the VS Code C# extension. Either way the probe runs at load time, so
a freshly installed server attaches on the **next** start.

`background_analysis` is scoped to `openFiles` on purpose. Whole-solution
analysis on a real Unity project never settles, and the one thing it buys —
diagnostics for files you have not opened — is what Unity's own compile already
tells you. `workspace/projectInitializationComplete` re-requests diagnostics for
attached buffers, because requests made while the workspace was still loading
come back empty and nothing retries them.

The `dotnet` build actions are **visible but unavailable** inside a Unity
project, explaining that Unity owns the build. They are not hidden: that is the
`available`-returns-a-string rule doing the teaching.

Unity's `Library/`, `Temp/` and `Logs/` need no picker excludes — every Unity
`.gitignore` already lists them and both `fd` and `rg` honour it.

### What talks to the editor

Three separate channels, and confusing them is the usual way to misread a
symptom:

- **`shim.lua`** is Unity → Neovim for *files*. It writes a fake `code` script
  that Unity is pointed at as its External Script Editor; the script resolves
  a per-project socket (`sha256(root)` under `$XDG_RUNTIME_DIR/nvim-unity`) and
  calls `v:lua.UnityOpenFromEditor` over `--remote-expr`. That global is the one
  `_G` entry this config sets, and it exists because `--remote-expr` can only
  call a global. Pointing Unity at the shim is also what makes Unity bind its
  control socket at all, which is what `messenger.lua` needs.
- **`messenger.lua`** is Neovim → Unity for *commands*: play, stop, pause,
  refresh, and later the test runner. It is Unity's own VS integration
  protocol, little-endian `int32` type + `int32` length + payload over UDP on
  `56000 + (pid % 1000) + 2`, with large replies fetched over a TCP port the
  UDP notice names. The type numbers are the C# enum's implicit values, so
  `M.TYPE` is the wire format and must not be reordered. Nothing is
  acknowledged, so every command goes through `send_checked`, which pings first
  and explains the silence rather than dropping the keypress.
- **`bridge.lua`** is Unity → Neovim for *state*. `:UnityCompanion` became an
  action; it writes a small `[InitializeOnLoad]` C# file into
  `Assets/NvimBridge` and hides it in `.git/info/exclude`, and the editor then
  writes `Library/nvim-unity/{state,diagnostics}.json`. Strictly one way and
  file-based: nothing the bridge does can hang the editor or interfere with a
  build.

`state.lua` watches the *directory*, not the files — each write replaces the
inode and a file watch follows the old one into the bin — plus a 2s liveness
tick, because a crashed editor leaves its state file behind and no file event
will ever say so. A clean quit deletes the file; that is how "closed" is told
from "idle". Notifications are transitions only, and the first read seeds
silently rather than announcing the state Unity was already in.

Unity's compile messages are deliberately **not** `vim.diagnostic` entries.
They are only as fresh as the last compile, so in the diagnostic namespace a
message you have already fixed would answer `]d` and follow you around the
buffer as if it were live. They live in `diagnostics.lua` and appear only when
asked for. `log.lua` prefers them and falls back to scraping `Editor.log` when
the project has no bridge.

### Autocommands in a language module

`lua/lang/unity/init.lua` owns a `BufReadPost`/`BufNewFile` autocommand, which
is the one exception to autocommands living in `core/autocmds.lua`: `core` may
not name a language, and the shim socket has to be bound without the user
asking. A language module's autocommands are named `lang_<name>_*`, must be
cheap and idempotent, and must return immediately outside their own projects.
Anything that can wait until `<Leader>r` should wait there instead.

### Tests, assets and attaching

**Tests are the messenger's second job.** `tests.lua` sends `ExecuteTests` with
a `TestMode:FullName` value — `TestRunnerApiListener.ExecuteTests` splits on the
first colon and returns without a word when there is none — and collects
`TestFinished` until `RunFinished`. A suite reports itself alongside its
children, so only a single-element `TestResultAdaptors` is a leaf worth
counting. Failures open the snacks picker the same way compile errors do, not
quickfix, because `log.lua` already set that precedent for "a list of places in
the code".

**A run holds the messenger open.** Unity multicasts results only to clients it
has heard from recently, so `messenger.keepalive_start` pings every two seconds
for the length of a run; without it a run reports its first few tests and then
goes quiet. It stops in `report()`, which is also the only place the in-flight
run is cleared.

`tests.at_cursor` returns a name **or the reason there is none**, and the three
reasons are different problems: not a C# buffer, no `c_sharp` parser installed,
or a cursor that is genuinely not in a method. An action that reports only the
last one sends you looking in the wrong place.

**`.meta` handling has no general hook, and that is the whole design
constraint.** The old config hooked neo-tree's `file_moved`/`file_deleted`
events; snacks' explorer has no event bus, and `BufFilePost` is not a
substitute — `:saveas` and `:file` do not move anything on disk, so carrying a
`.meta` there would strand it. So the supported path is explicit: the Refactor
actions rename and delete, with `assets.rename` going through
`Snacks.rename.rename_file` so the language server hears about it before the
file moves and a C# namespace follows.

Because that leaves a real gap, *List assets with a missing or orphaned `.meta`*
is the safety net for a rename done anywhere else. Both halves matter: an asset
with no `.meta` gets a **new GUID** at the next import and every scene reference
to it breaks, and an orphaned `.meta` is the other end of the same rename.

**Attaching is one adapter and two endpoints.** `dap.lua` owns `vstuc`, found in
the VS Code extension directory, and it is registered in nvim-dap's **function**
form so the four extension directories are globbed when a session starts rather
than on every start of an editor that is not debugging Unity. The editor path is
a `configurations` provider: one `attach` config per running editor, the
buffer's own project first, so a project with one editor open needs no choice.
`projectPath` is the *editor's* project rather than ours, for the case of
attaching to a second one.

`editor.list()` earns its filters on a real machine: a Hub session also runs
`unityhub-bin`, `UnityShaderCompiler`, a licensing client and one
`AssetImportWorker` per core, and the `-batchMode` check plus the
`project or comm == "Unity"` gate is what keeps them out of the attach list.

**The device path is the same attach with a longer piece of string.** Same
adapter, same `attach` request, pointed at a local port `adb` has forwarded.
What differs is that every step fails as "connection refused" at the adapter —
no device, one never authorised, an app that is not running, a build with no
script debugging — so `android/player.lua` checks them in order and the first
failure is the informative one. The port is the hard part: Unity announces it on
its first log line and never again, so on a build that has been up an hour the
announcement has rolled out of the ring buffer. The listening socket is still in
`/proc`, so that is what is trusted and the log is only the tie-breaker when
more than one candidate is in range.

A forward outlives the debugger that asked for it, and whoever binds that port
next inherits a pipe to a tablet, so `release_with_session` tears it down on
four dap events and `VimLeavePre` sweeps whatever is left.

Deliberately left behind from the old Android stack: `logcat.lua` and
`monitor.lua`, 430 lines whose job was a log window and a timer that re-attached
it across app restarts. `core.task` is the log window, so the log is now
`adb logcat --pid` as an unqueued task. The restart-following timer is not
ported; if a crash-restart loop becomes annoying enough to chase, that is what
to reach for.

### Where the phases are

Phases 1, 2 and 3 are done. Phase 1: project detection (`Assets/` +
`ProjectSettings/ProjectVersion.txt`, cached per directory), editor and
solution resolution, the Unity asset filetypes, `Editor.log` scraping, the log
tail through `core.task`, and Scripting Reference lookup that prefers the
locally installed docs. Phase 2: the shim, the messenger, the bridge and the
state watcher, plus the play/stop/pause/resume/restart/refresh actions. Phase 3:
tests, `.meta` sidecar handling, and the editor and Android attach paths, all
described above.

`unity` carries `ft = { "cs" }` **only** so the debug layer can filter its
configurations provider by filetype — it still declares no `lsp` key, because
`csharp` owns roslyn_ls for those same buffers.

Nothing from the old integration is outstanding. What was dropped rather than
deferred: the Unity-specific heirline component, `condition.lua` and
`completion.lua` on the debug side, and the logcat restart monitor above.

There are **no `:Unity*` commands**. The old config had eight; here every one
of them is an action, because `<Leader>r` is the only entry point a language
module gets and a second one would be the fragmentation this rewrite removed.

## Working agreement for agents

- Follow the layer boundaries even when a shortcut is one line shorter. The
  boundaries are the deliverable.
- Do not add a plugin without being asked. Suggest it instead.
- Do not port a module from `../` without being asked.
- Do not reintroduce a framework abstraction (a global `opts.mappings` table, a
  `polish` hook, a community spec index) — these are what was removed.
- Run `just check` before reporting a change complete, and say so if it fails.
- Keep this file current. A structural decision that is not written here will
  be undone by the next change.
