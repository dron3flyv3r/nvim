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
      { "grr / gri", "references / implementations" },
      { "grn", "RENAME this variable/function everywhere (LSP, cross-file)" },
      { "gra", "code action" },
      { "K", "hover documentation" },
      { "gK  or  <Leader>lh", "signature help (params + types)" },
      { "gO", "symbols in this file" },
      { "<Leader>ls / lG", "search symbols in file / whole workspace" },
      { "<Leader>lS", "toggle the aerial outline sidebar" },
      { "ær / ør", "next / previous use of this symbol", "new" },
      { "``", "back to position before the last jump" },
      { "`.", "jump to your last edit" },
      { ":jumps", "show the whole jump history" },
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
      { "<Leader>ld", "hover the diagnostic under the cursor" },
      { "<Leader>lD", "search all diagnostics" },
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
      { "<Leader>rl", "re-run the last task ← the one you'll wear out", "new" },
      { "<Leader>rt", "toggle the task list", "new" },
      { "<Leader>rq", "open the last task's output", "new" },
      { "<Leader>rc", "run an arbitrary shell command", "new" },
      { "<Leader>ra", "task action — stop, restart, dispose", "new" },
      { "æq / øq", "step through build errors (they land in quickfix)", "new" },
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
    "TOOLS",
    {
      { "<Leader>gt / gb / gc", "git status / branches / commits" },
      { "æg / øg", "next / previous git hunk", "new" },
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
