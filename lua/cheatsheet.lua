-- A floating cheatsheet for this config's navigation and action keys.
--
-- Opened with `?` (normal/visual) or `<F1>` (also insert) or `:Cheatsheet`.
-- This is a plain scratch buffer, so every normal Vim motion works inside it:
-- `/` to search, `<C-d>`/`<C-u>` to scroll, `n`/`N` to step through matches.
--
-- Entries marked `*` are custom to this config rather than AstroNvim defaults.

local M = {}

--- Width of the key column, in display cells.
local KEY_WIDTH = 22
--- Max total window width, in display cells.
local MAX_WIDTH = 94

---@alias CheatEntry [string, string]|[string, string, "new"]

---@type { [1]: string, [2]: CheatEntry[] }[]
local SECTIONS = {
  {
    "DANISH LAYOUT  (AltGr-free replacements)",
    {
      { "ø  /  æ", "= [  and  ]   — prefix for all pair-jumps", "new" },
      { "Ø  /  Æ", "= {  and  }   — jump by paragraph / block", "new" },
      { "å  /  Å", "= $  and  ^   — end / first-char of line", "new" },
      { "æb / øb", "next / previous buffer", "new" },
      { "æd / ød", "next / previous diagnostic", "new" },
      { "æq / øq", "next / previous quickfix item", "new" },
      { "æg / øg", "next / previous git hunk", "new" },
      { "æj / øj", "next / previous notebook cell", "new" },
      { "<Leader>sv / sh", "split vertical / horizontal (no AltGr)", "new" },
      { "g?", "search backwards (the original ?)", "new" },
      { "?  or  <F1>", "this cheatsheet", "new" },
    },
  },
  {
    "MOVING AROUND",
    {
      { "<C-d> / <C-u>", "half page down / up  ← the main scroll" },
      { "<C-f> / <C-b>", "full page down / up" },
      { "<C-e> / <C-y>", "scroll one line, cursor stays put" },
      { "zz / zt / zb", "center / top / bottom the current line" },
      { "H / M / L", "top / middle / bottom of the screen" },
      { "Ø / Æ", "previous / next paragraph or block", "new" },
      { "%", "jump to the matching bracket" },
      { "w / b / e", "next word / back a word / end of word" },
      { "f<char> ; ,", "jump to char on line, then repeat fwd / back" },
      { "120G  /  50%", "go to line 120 / halfway through the file" },
      { "gg / G", "top / bottom of file" },
    },
  },
  {
    "DEFINITIONS & JUMPING BACK",
    {
      { "gd", "go to definition" },
      { "<C-o>", "jump BACK  ← works across files" },
      { "<C-i>", "jump FORWARD again" },
      { "gy / gD", "type definition / declaration" },
      { "grn", "RENAME this variable/function everywhere (LSP, cross-file)" },
      { "gra", "code action" },
      { "K", "hover documentation" },
      { "gK  or  <Leader>lh", "signature help (params + types)" },
      { "gO", "symbols in this file" },
      { "<Leader>ls / lG", "search symbols in file / whole workspace" },
      { "<Leader>lS", "toggle the aerial outline sidebar" },
      { "(note)", "all of these open the <Leader>ff picker — see below", "new" },
      { "ær / ør", "next / previous use of this symbol", "new" },
      { "``", "back to position before the last jump" },
      { "`.", "jump to your last edit" },
      { ":jumps", "show the whole jump history" },
    },
  },
  {
    "FINDING EVERY USE   (LSP, in the same picker as <Leader>ff)",
    {
      { "<Leader>lR  or  grr", "every REFERENCE to this symbol", "new" },
      { "<Leader>li  or  gri", "every IMPLEMENTATION of this interface/method", "new" },
      { "<Leader>lk", "INCOMING calls — who calls this  (k = up the tree)", "new" },
      { "<Leader>lj", "OUTGOING calls — what this calls  (j = down the tree)", "new" },
      { "<Leader>lG", "search symbols across the whole solution", "new" },
      { "(in the picker)", "type to fuzzy-filter, preview is on the right", "new" },
      { "<C-v> / <C-s>", "open the hit in a vertical / horizontal split", "new" },
      { "<C-q>", "send the FILTERED list to quickfix, then walk it with æq", "new" },
      { "<Leader>f<CR>", "reopen the last picker where you left it", "new" },
      { "(why)", "grep finds the WORD; these find the actual symbol", "new" },
    },
  },
  {
    "BUFFERS   (the set belongs to the current TAB PAGE)",
    {
      { "<Tab> / <S-Tab>", "next / previous buffer", "new" },
      { "<Leader>1 … 9", "jump straight to buffer N in the tabline", "new" },
      { "<A-1> … <A-9>", "same, one-handed", "new" },
      { "æb / øb", "next / previous buffer", "new" },
      { "<C-^>", "toggle between the last two buffers" },
      { "<Leader>c", "close buffer" },
      { "<Leader>bb / bd", "pick a buffer from the tabline / to close" },
      { "<Leader>fb", "fuzzy-find open buffers" },
      { "<Leader>bc", "close all buffers EXCEPT this one" },
      { "<Leader>br / bl", "close all buffers to the right / left" },
      { "<Leader>o / <Leader>i", "jump back / forward (safe <C-o>/<C-i>)", "new" },
    },
  },
  {
    "LEAVE THE SPOT, COME BACK TO IT",
    {
      { "<BS>", "back to where you were before the last jump", "new" },
      { "", "press again to bounce back — gg, edit, <BS>, carry on" },
      { "<Leader><BS>", "back to the last thing you EDITED (g;)", "new" },
      { "<Leader>ma", "drop an anchor here", "new" },
      { "<Leader>mj", "jump to the anchor (survives other jumps)", "new" },
      { "(note)", "a jump = gg G /search { } marks, definitions — not typing" },
    },
  },
  {
    "TABS = SEPARATE BUFFER SETS",
    {
      { "<Leader>Tn", "new tab — starts an EMPTY buffer set", "new" },
      { "<Leader>Tc / To", "close this tab / close all other tabs", "new" },
      { "<Leader>Tl / Th", "next / previous tab", "new" },
      { "æt / øt", "next / previous tab", "new" },
      { "(note)", "splits inside one tab SHARE its buffer set" },
    },
  },
  {
    "WINDOWS & SPLITS",
    {
      { "<Leader>sv / sh", "split vertical / horizontal", "new" },
      { "<Leader>sc / so", "close this split / close all others", "new" },
      { "<C-h/j/k/l>", "move between splits" },
      { "<Leader>sr", "RESIZE MODE — then hjkl freely, <Esc> to exit", "new" },
      { "<C-arrows>", "nudge the split size one step" },
      { "<Leader>s=", "equalize all split sizes", "new" },
      { "<Leader>sm", "ZOOM this split — press again to restore the layout", "new" },
      { "<Leader>sw", "pick a window by letter (best with 3+ columns)", "new" },
      { "<Leader>sH/sJ/sK/sL", "swap this split with its neighbour", "new" },
      { "<Leader>e", "toggle the file explorer" },
    },
  },
  {
    "AI",
    {
      { "<Leader>aa", "toggle Claude Code (right split)", "new" },
      { "<Leader>af", "jump into the Claude window", "new" },
      { "<Leader>ab", "add THIS buffer to Claude's context", "new" },
      { "<Leader>as", "(in visual) send the selection to Claude", "new" },
      { "<Leader>as", "(in neo-tree) add the file under the cursor", "new" },
      { "<Leader>ay / ad", "accept / reject Claude's proposed diff", "new" },
      { "<Leader>ar / an", "resume a session / continue the last one", "new" },
      { "<Leader>am", "pick which Claude model to use", "new" },
      { "<Leader>aS", "Claude connection status", "new" },
      { "<Leader>ac", "toggle Copilot ghost text (this buffer)", "new" },
      { "<Leader>aC", "toggle Copilot entirely (global)", "new" },
      { "<Leader>as", "Copilot status", "new" },
      { "<Leader>ax", "toggle Codex" },
      { "<M-l>", "accept the rest of the Copilot line" },
      { "<M-]> / <M-[>", "next / previous Copilot suggestion" },
      { "<C-]>", "dismiss the suggestion" },
    },
  },
  {
    "FINDING THINGS",
    {
      { "<Leader>ff", "find files" },
      { "<Leader>fw", "grep the whole project" },
      { "<Leader>fo", "recently opened files" },
      { "<Leader>fs", "smart find (buffers + recent + files)" },
      { "<Leader>fc", "find the word under the cursor" },
      { "<Leader>fl", "find a line in this buffer" },
      { "<Leader>fk", "search your own keymaps" },
      { "<Leader>f'", "list marks" },
      { "<Leader>fu", "browse undo history" },
      { "<Leader>fT", "find TODO / FIXME comments" },
      { "<Leader>fa", "jump into your nvim config files" },
      { "<Leader>f<CR>", "resume the last picker" },
      { "<Tab> then <C-q>", "send picked results to the quickfix list" },
    },
  },
  {
    "QUICKFIX & DIAGNOSTICS",
    {
      { "<Leader>xx", "LIST every problem in the project (picker + preview)", "new" },
      { "<Leader>xX", "list the problems in THIS FILE only", "new" },
      { "<Leader>ld  or  gl", "open the error you're standing on", "new" },
      { "  press it again", "step INSIDE the popup — scroll it, / it, y it", "new" },
      { "<Leader>ue", "toggle ERRORS ONLY (hide warnings + hints)", "new" },
      { "<Leader>la  or  xa", "QUICK FIX = code action (VS Code's Ctrl+.)", "new" },
      { "<Leader>xd", "put ALL diagnostics in the quickfix list", "new" },
      { "<Leader>xe", "put errors only in the quickfix list", "new" },
      { "<Leader>xb", "this buffer's diagnostics → location list", "new" },
      { "<Leader>xq", "open the quickfix list (empty until filled!)" },
      { "<Leader>xc", "close the quickfix / location list", "new" },
      { "æq / øq", "next / previous quickfix item", "new" },
      { "Æq / Øq", "last / first quickfix item", "new" },
      { "æd / ød", "next / previous diagnostic", "new" },
      { "æe / øe", "next / previous ERROR only", "new" },
      { "æw / øw", "next / previous warning", "new" },
      { "<Leader>lD", "same as <Leader>xx (AstroNvim's key for it)" },
      { "(note)", "æd / ød skip whatever <Leader>ue is hiding", "new" },
      { "(scope)", "these list what the SERVERS have analysed = open files", "new" },
      { "<Leader>Ue", "…so for every C# error in the solution, ask Unity", "new" },
      { ":cdo s/a/b/gc | update", "replace across every quickfix entry" },
      { ":cfdo <cmd>", "run a command once per quickfix FILE" },
    },
  },
  {
    "EDITING",
    {
      { 'ci( ci" ci{', "change INSIDE brackets / quotes / braces" },
      { 'da( da" ci[', "delete AROUND (includes the delimiters)" },
      { "cif / vaf", "change inside / select a whole function" },
      { "<Leader>/", "toggle comment (works in visual too)" },
      { "gcc / gc<motion>", "comment line / comment over a motion" },
      { "< / >", "indent left / right (unshifted on Danish!)" },
      { "<Leader>w", "save" },
      { "(automatic)", "saved 1s after you stop typing, and on leaving", "new" },
      { "", "a buffer/window — including files a code action edited", "new" },
      { "u / <C-r>", "undo / redo" },
      { ".", "repeat the last change" },
      { "ma  then  `a", "set mark a, then jump to it" },
    },
  },
  {
    "MOVING & DUPLICATING LINES   (normal, visual AND insert)",
    {
      { "<A-j> / <A-k>", "move the line — or the selection — down / up" },
      { "<A-h> / <A-l>", "move it out / in (dedent / indent)" },
      { "3<A-j>", "counts work; a whole run of moves undoes as one" },
      { "<A-S-j> / <A-S-k>", "duplicate the line/selection below / above", "new" },
      { "<C-t> / <C-d>", "indent / dedent from INSIDE insert mode", "new" },
      { "(note)", "<A-l> in insert is copilot's accept-line, not indent" },
      { "yyp", "the old-fashioned duplicate, if your hands know it" },
    },
  },
  {
    "MULTIPLE CURSORS   (for renaming a variable, use grn instead)",
    {
      { "<C-n>", "select the word under the cursor", "new" },
      { "<C-n> again", "add the next occurrence — repeat as needed", "new" },
      { "q / Q", "skip this match / remove this cursor", "new" },
      { "<Leader>A", "select EVERY occurrence in the buffer at once", "new" },
      { "<C-Up> / <C-Down>", "add a cursor on the line above / below", "new" },
      { "<Leader>N", "drop a lone cursor right here", "new" },
      { "then just type", "c I A i s x ~ … every cursor does the same thing" },
      { "<Esc>", "back to a single cursor" },
      { "n / N", "in multi-cursor mode: go to next / previous cursor" },
      { "(note)", "<C-Up>/<C-Down> no longer resize splits — use <Leader>sj/sk" },
      { "cgn  then  .", "no-plugin alternative: change match, `.` repeats it" },
    },
  },
  {
    "SESSIONS",
    {
      { "(automatic)", "`:qa` saves — `nvim` or `nvim .` restores", "new" },
      { "", "`nvim file.py` never restores; it just opens the file" },
      { "<Leader>S.", "load this directory's session" },
      { "<Leader>Sl", "load the last session" },
      { "<Leader>Sf", "pick a session to load" },
      { "<Leader>Ss", "save the current session" },
      { "<Leader>Sd", "delete a session" },
    },
  },
  {
    "RUNNING & BUILDING   (overseer — reads the project, not the filetype)",
    {
      { "<Leader>rr", "run a task — lists your justfile / Makefile targets", "new" },
      { "<Leader>rf", "python: run THIS file as `python -m pkg.mod`", "new" },
      { "<Leader>rl", "re-run the last task ← the one you'll wear out", "new" },
      { "(note)", "rf switches target when you move to lec6; rl repeats" },
      { "(note)", "output opens by itself, full width along the bottom" },
      { "(note)", "tqdm & friends redraw in place — the pty tracks the pane" },
      { "<Leader>ri", "jump INTO the output & type — stdin, y/N, Ctrl-C", "new" },
      { "<Esc>", "…and back out of it" },
      { "<Leader>ro", "open the last task's output (just look at it)", "new" },
      { "q", "…in the output pane: close it" },
      { "<Leader>rq", "QUEUE a task — runs after the current one finishes", "new" },
      { "<Leader>rk", "kill the running task", "new" },
      { "<Leader>rK", "kill everything — running and queued", "new" },
      { "<Leader>rt", "toggle the task list (right sidebar, q closes)", "new" },
      { "<Leader>rc", "run an arbitrary shell command", "new" },
      { "<Leader>ra", "task action — stop, restart, dispose", "new" },
      { "æq / øq", "step through build errors (they land in quickfix)", "new" },
    },
  },
  {
    "RUST   (<Leader>R… — what rust-analyzer knows that Cargo.toml doesn't)",
    {
      { "<Leader>rr", "cargo build / run / test / clippy — the whole crate", "new" },
      { "<Leader>Rr", "run THIS — pick the bin, example or test at the cursor", "new" },
      { "<Leader>Rl", "re-run that same one, no picker  ← the loop key", "new" },
      { "<Leader>Rt", "test — just the #[test] fn / mod you're standing in", "new" },
      { "<Leader>Rd", "debug it (codelldb) — then the <Leader>d keys", "new" },
      { "(note)", "all of these land in the same bottom output pane", "new" },
      { "<Leader>RD", "the FULL rustc error — quoted source, carets, help", "new" },
      { "(why)", "LSP only carries the first line; borrow errors need the rest" },
      { "<Leader>Rx", "explain this error code (rustc --explain E0502)", "new" },
      { "<Leader>Re", "expand the macro — see what a #[derive] generated", "new" },
      { "<Leader>la", "QUICK FIX, with a diff of what it will do", "new" },
      { "<Leader>Ra", "…the same list, kept in rust-analyzer's groups, no diff", "new" },
      { "<Leader>Rm", "go to the parent module (the `mod foo;` line)", "new" },
      { "<Leader>Rc", "open this crate's Cargo.toml", "new" },
      { "<Leader>Ro", "open docs.rs for the symbol under the cursor", "new" },
      { "<Leader>Rj / Rk", "move the whole item (fn, impl, arm) down / up", "new" },
      { "<Leader>Rp", "rebuild proc macros — when #[derive] stops working", "new" },
      { "K", "hover, with links — press again to jump into the type", "new" },
      { "(errors)", "appear AS YOU TYPE — no need to save first", "new" },
      { "(new file?)", "a .rs file no `mod` reaches gets no completion and no", "new" },
      { "", "hints — that is Rust, not a bug. Open the mod.rs, look", "new" },
      { "", "for `unlinked-file` on line 1, and <Leader>la writes it", "new" },
    },
  },
  {
    "RUST — IN Cargo.toml   (crates.nvim; same <Leader>R prefix)",
    {
      { "<Leader>Rv", "every published version of this crate", "new" },
      { "<Leader>Rf", "its features, and which ones you have on", "new" },
      { "<Leader>Rd", "what this crate itself depends on", "new" },
      { "<Leader>Ru / RU", "UPDATE (within your range) / UPGRADE (bump it)", "new" },
      { "<Leader>Ra / RA", "…the same two, for every crate in the file", "new" },
      { "<Leader>Ro", "open docs.rs for this crate", "new" },
      { "(note)", "versions also show as virtual text as you type" },
    },
  },
  {
    "NOTEBOOK   (molten — a live Jupyter kernel in the file you're editing)",
    {
      { "(cells)", "a cell is the code between two `# %%` lines", "new" },
      { "<Leader>jj", "RUN THIS CELL — output appears under it", "new" },
      { "<Leader>jn", "run it and move to the next  ← Colab's Shift+Enter", "new" },
      { "<Leader>jj (visual)", "run just the selection", "new" },
      { "<Leader>jl", "run this one line", "new" },
      { "<Leader>jA", "run every cell, top to bottom", "new" },
      { "<Leader>jr", "re-run the cell you're standing on", "new" },
      { "<Leader>jc / ja", "new cell below / above", "new" },
      { "æj / øj", "next / previous cell", "new" },
      { "<Leader>je", "step INTO the output — scroll it, select from it", "new" },
      { "<Leader>jo / jh", "show / hide the output float", "new" },
      { "<Leader>jy / jd", "copy the output / delete this cell's output", "new" },
      { "<Leader>jx", "interrupt — the cell's KeyboardInterrupt", "new" },
      { "<Leader>jZ", "restart the kernel and clear every output", "new" },
      { "<Leader>jk", "register THIS project's venv as the kernel", "new" },
      { "(note)", "…needs ipykernel in it: `uv add --dev ipykernel`" },
      { "(note)", "a .ipynb opens as Python and saves back as .ipynb" },
      { "<Leader>j?", "what's missing — run this when nothing happens", "new" },
    },
  },
  {
    "GIT — LOOKING AT CHANGES   (in the file you're editing)",
    {
      { "æg / øg", "next / previous changed hunk", "new" },
      { "<Leader>gp", "peek at the hunk under the cursor" },
      { "<Leader>gr / gR", "REVERT this hunk / the whole file" },
      { "<Leader>gs / gS", "stage this hunk / the whole file" },
      { "<Leader>gl / gL", "blame this line / with the full commit" },
      { "<Leader>gt", "changed files (picker)" },
      { "<Leader>gb / gc", "branches / commits" },
      { "<Leader>go", "open this line on GitHub" },
    },
  },
  {
    "GIT — THE DIFF VIEW   (<Leader>gd — Rider's Changes window)",
    {
      { "<Leader>gd", "every change: file list left, diff right", "new" },
      { "<Leader>gD", "…against a branch you pick", "new" },
      { "<Leader>gh / gH", "history of this file / of the repo", "new" },
      { "  inside it", "", "new" },
      { "  the two panes", "GREEN bar = your file · RED bar = what it's compared to", "new" },
      { "  n  /  N", "next / previous change — rolls into the next file", "new" },
      { "  <Tab> / <S-Tab>", "jump straight to the next / previous file", "new" },
      { "  <Leader>gr", "REVERT this change — from either pane", "new" },
      { "  <Leader>gl", "…just this ONE line", "new" },
      { "  V j <Leader>gr", "…exactly the lines you selected", "new" },
      { "  <Leader>gR", "…the whole file", "new" },
      { "  u", "UNDO a revert — from either pane", "new" },
      { "  (nothing left)", "reverted it all? the view goes blank — q closes it", "new" },
      { "  /foo<CR> then /<CR>", "search — `n` is taken here, `g?<CR>` goes back", "new" },
      { "  to undo a deletion", "stand in the LEFT pane — the lines are only there", "new" },
      { "  - / S / U", "stage file / stage all / unstage all", "new" },
      { "  g?", "diffview's own key list", "new" },
      { "  q", "close", "new" },
    },
  },
  {
    "GIT — STASH   (put changes aside, take them back later)",
    {
      { "<Leader>gz", "stash tracked changes, asks for a message", "new" },
      { "<Leader>gZ", "…including untracked files (-u)", "new" },
      { "<Leader>gT", "the stash list — Enter POPS the one you pick", "new" },
      { "  a  /  d", "apply and keep it / drop it (normal mode)", "new" },
      { "  <C-y> / <C-x>", "the same two without leaving the filter box", "new" },
      { ":Stash -u wip on x", "stash with the message on one line", "new" },
      { ":Stash -a", "…and ignored files too (build/, .venv/)", "new" },
    },
  },
  {
    "TERMINAL",
    {
      { "<F7>", "toggle a terminal — works from insert and from inside it" },
      { "<Leader>tf / th / tv", "terminal: floating / below / beside" },
      { "<Leader>tp", "python REPL" },
      { "<C-\\><C-n>", "leave terminal insert mode (back to normal)" },
    },
  },
  {
    "TOGGLES   (<Leader>u… — each one says what it switched to)",
    {
      { "<Leader>uw  or  <A-z>", "WRAP long lines, this window only", "new" },
      { "  while wrapped", "j / k move by screen line; 5j still = 5 real lines", "new" },
      { "<Leader>ue", "errors only — hide warnings and hints", "new" },
      { "<Leader>ud", "all diagnostics off / on" },
      { "<Leader>uv / uV", "virtual text / virtual lines off / on" },
      { "<Leader>uH", "inlay type hints" },
      { "<Leader>uf / uF", "FORMAT ON SAVE off — this buffer / everywhere", "new" },
      { "<Leader>us", "spell check" },
      { "<Leader>un", "line numbers" },
      { "<Leader>uW", "AUTOSAVE toggle -- ON by default, so 1st press turns it OFF  (uw is wrap)", "new" },
      { "<Leader>uZ", "zen mode (one window, no distractions)" },
    },
  },
  {
    "TOOLS",
    {
      { "<Leader>gd", "git: the diff view — see the GIT sections above", "new" },
      { "<Leader>db / dc", "toggle breakpoint / start-continue (F9, F5)" },
      { "<Leader>du", "toggle the debugger UI" },
      { "<Leader>uH", "toggle inlay type hints" },
      { "<Leader>lw", "C/C++: switch between source and header", "new" },
      { "<Leader>lv", "python: pick a virtualenv" },
      { "<Leader>v*", "uv commands (python env, add, sync, run)", "new" },
      { "<Leader>pS / pu", "sync plugins / check for updates" },
      { ":Mason", "install language servers / formatters" },
    },
  },
}

local NS = vim.api.nvim_create_namespace "cheatsheet"

--- Build the rendered lines plus the highlight ranges to apply to them.
---@return string[] lines, table[] marks
local function render()
  local lines, marks = {}, {}

  local function add(text, hl, col_start, col_end)
    lines[#lines + 1] = text
    if hl then marks[#marks + 1] = { #lines - 1, col_start or 0, col_end or -1, hl } end
  end

  for i, section in ipairs(SECTIONS) do
    if i > 1 then add "" end
    add("  " .. section[1], "CheatsheetHeader")
    add ""
    for _, entry in ipairs(section[2]) do
      local key, desc, tag = entry[1], entry[2], entry[3]
      -- Pad by display width (æ/ø/å are multi-byte) but slice by byte offset,
      -- which is what extmarks expect.
      local pad = math.max(1, KEY_WIDTH - vim.fn.strdisplaywidth(key))
      local text = "    " .. key .. string.rep(" ", pad) .. desc
      local key_end = 4 + #key
      add(text)
      local row = #lines - 1
      marks[#marks + 1] = { row, 4, key_end, tag == "new" and "CheatsheetKeyNew" or "CheatsheetKey" }
      marks[#marks + 1] = { row, key_end + pad, -1, "CheatsheetDesc" }
    end
  end

  add ""
  add("  q / <Esc> close   ·   / search   ·   n next match   ·   <C-d>/<C-u> scroll", "CheatsheetHint")

  return lines, marks
end

local function set_highlights()
  local function def(name, link) vim.api.nvim_set_hl(0, name, { link = link, default = true }) end
  def("CheatsheetHeader", "Title")
  def("CheatsheetKey", "Identifier")
  def("CheatsheetKeyNew", "DiagnosticOk")
  def("CheatsheetDesc", "Normal")
  def("CheatsheetHint", "Comment")
end

---@type integer? Window handle of the open cheatsheet, if any.
local win = nil

function M.close()
  if win and vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  win = nil
end

function M.open()
  if win and vim.api.nvim_win_is_valid(win) then return M.close() end -- toggle
  set_highlights()

  local lines, marks = render()

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  for _, m in ipairs(marks) do
    local row, start_col, end_col = m[1], m[2], m[3]
    -- A negative end_col means "to end of line"; extmarks want the real byte length.
    if end_col < 0 then end_col = #lines[row + 1] end
    vim.api.nvim_buf_set_extmark(buf, NS, row, start_col, { end_col = end_col, hl_group = m[4] })
  end
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "cheatsheet"

  local content_width = 0
  for _, l in ipairs(lines) do
    content_width = math.max(content_width, vim.fn.strdisplaywidth(l))
  end
  local width = math.min(math.max(content_width + 2, 50), MAX_WIDTH, vim.o.columns - 4)
  local height = math.min(#lines, math.floor(vim.o.lines * 0.85))

  win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " Cheatsheet ",
    title_pos = "center",
  })
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  vim.wo[win].winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder,CursorLine:PmenuSel"

  for _, key in ipairs { "q", "<Esc>", "?", "<F1>" } do
    vim.keymap.set("n", key, M.close, { buffer = buf, nowait = true, desc = "Close cheatsheet" })
  end
  -- Clean up our handle if the window goes away by any other route.
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function() win = nil end,
  })
end

return M
