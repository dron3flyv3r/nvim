local M = {}
local NS = vim.api.nvim_create_namespace "core_cheatsheet"
local win

local SECTIONS = {
  {
    "PROJECT ACTIONS",
    {
      { "<Leader>r", "actions valid in this buffer and project" },
      { "<Leader>R", "repeat the last action" },
      { "type to filter", 'the menu is searched: "debug", "clippy", "test"' },
      { "<Tab> / <S-Tab>  ·  <CR>", "move down / up the filtered list · run it" },
      { ":ActionsStatus", "what was detected, and why something is unavailable" },
      { ":SessionSave / Restore / Delete", "manage the session for this project" },
      { "h / q  (bottom pane)", "hide it / close this occupant" },
      { "<Tab> / <S-Tab>  (pane)", "next / previous: terminal, task output, program output, REPL" },
    },
  },
  {
    "DEBUGGING  (<Leader>d…)",
    {
      { "<Leader>r  → Debug", "start a session; the language decides how" },
      { "<F5> / dc", "continue, or the Debug menu when nothing is running" },
      { "<F10> / dn  ·  <F11> / di", "step over · step into" },
      { "<F12> / do  ·  dt", "step out · run to cursor" },
      { "dj / dk", "down / up a stack frame" },
      { "db / dB / dh / dl", "breakpoint · conditional · after N hits · logpoint" },
      { "dL / dm / dx", "list them · mute them · delete them" },
      { "K  (while stopped)", "the runtime value, not the LSP's" },
      { "de / dw", "evaluate an expression · watch one" },
      { "ds / dv / du", "frames · scopes · the panel" },
      { "dr / dq", "REPL · stop the session" },
      { "<Leader>R", "run the last debug action again, same arguments" },
    },
  },
  {
    "GIT  (<Leader>g…)",
    {
      { "gg / gm", "Neogit: stage, commit, push, branch, stash · merge" },
      { "gd / gD", "review every change · review against a branch" },
      { "gh / gH", "history of this line or selection · of the repository" },
      { "øg / æg", "next / previous hunk" },
      { "gp / gP", "preview this hunk inline · in a popup" },
      { "gs / gS / gu", "stage this hunk · the file · undo the last stage" },
      { "gr / gR", "reset this hunk or selection · the whole file" },
      { "gb / gB", "toggle line blame · full blame for this line" },
    },
  },
  {
    "DIFF REVIEW  (inside <Leader>gd)",
    {
      { "?", "the key legend along the bottom; nothing is written until q" },
      { "n / N", "next / previous change, walking into the next file" },
      { "r / R  ·  u", "revert this change · the file · undo a revert" },
      { "<Leader>gl  ·  x <Leader>gr", "revert this line · the selected lines" },
      { "x <Leader>gk  ·  <Leader>gw", "keep these lines, revert the rest · undo a formatter" },
      { "gf", "leave the review at this file, settling it first" },
      { "q", "Save, Discard or Cancel the whole review" },
      { "H / L / B / X  (merge)", "take ours · theirs · both · drop both" },
      { "<CR>  (merge)", "take this line or selection into the resolution" },
      { "gH / gL / gB  (merge)", "the same, for the whole file" },
      { "<Leader>cb  (merge)", "show BASE for this conflict; <CR> there takes lines" },
      { "]r / [r  ·  <Tab>  (merge)", "check a resolution · next conflicted file" },
    },
  },
  {
    "CLAUDE  (<Leader>a…)",
    {
      { "aa / af", "toggle the agent · focus it" },
      { "ac / ar", "continue the last session · pick one to resume" },
      { "ab", "add this buffer to its context" },
      { "as", "send the selection, or the file under the cursor in a picker" },
      { "ay / ad", "accept · reject the diff it proposes" },
      { "/model  ·  /clear", "typed in its terminal, not a keymap" },
    },
  },
  {
    "FILES YOU RETURN TO",
    {
      { "<Leader>m", "tag or untag this file" },
      { "<Leader>M", "the tag list; dd and p reorder it, q commits" },
      { "<Leader>1 … 4", "jump to a tag by index" },
      { "øg / æg", "next / previous tag" },
      { "<Leader>sm", "marks, when the target is a line rather than a file" },
    },
  },
  {
    "FINDING THINGS",
    {
      { "<Leader><Space>", "smart find: open buffers first, then files" },
      { "<Leader>ff / fr", "find files / recent files" },
      { "<Leader>/", "grep the project" },
      { "<Leader>, / e", "buffers / file explorer" },
      { "<Leader>sb / sB", "lines in this buffer / grep the open buffers" },
      { "<Leader>sk", "mappings — built-in keys are :help index.txt" },
      { "<Leader>sh / sr", "help pages / resume the last picker" },
      { "j / k  ·  <CR>", "move the selection · open it" },
      { "i  or  /", "reach the filter when the list starts focused" },
    },
  },
  {
    "CODE NAVIGATION",
    {
      { "grd  (gd)", "go to definition" },
      { "grr / gri / grt", "references / implementations / type definition" },
      { "grn / gra", "rename, previewed live / code action, previewed as a diff" },
      { "gggqG / gqip / x gq", "format via the LSP: file · block · selection" },
      { "K / gO", "hover documentation / symbols in this document" },
      { "ød / æd", "next / previous diagnostic" },
      { "<Leader>sd / sD", "project / buffer diagnostics, with preview" },
      { "<Leader>uv", "expand every diagnostic inline, not only the cursor line" },
      { "]] / [[", "next / previous use of the symbol under the cursor" },
      { "<Leader>uh", "inlay hints on or off" },
      { "<Leader>uc", "reference and implementation counts on or off, everywhere" },
      { "grx", "run the code lens under the cursor" },
    },
  },
  {
    "COMPLETION & PAIRS",
    {
      { "<C-j> / <C-k>", "move down / up the menu" },
      { "<C-l>", "accept" },
      { "<C-space> / <C-e>", "open the menu / dismiss it" },
      { "<C-b> / <C-f>", "scroll the documentation" },
      { "<C-x><C-o>", "the native menu, which stays configured underneath" },
      { '( [ { "', "the closing half is added; type it again to step over it" },
      { "<CR>  (inside a pair)", "the closing half moves down to its own line" },
      { "<BS>  (empty pair)", "delete both halves" },
    },
  },
  {
    "DANISH ALIASES",
    {
      { "æ / ø", "[ / ] prefixes" },
      { "Æ / Ø", "{ / } paragraph motions" },
      { "å / Å", "$ / ^ line ends" },
      { "øb / æb", "next / previous buffer" },
      { "øq / æq", "next / previous quickfix entry" },
    },
  },
  {
    "WINDOWS & BUFFERS",
    {
      { "<C-h/j/k/l>", "move between windows, terminal included" },
      { "<C-Up/Down/Left/Right>", "resize this window, terminal included" },
      { "<Leader>wv / wh", "split vertically / horizontally" },
      { "<Leader>wc / wo", "close this window / close the others" },
      { "<Leader>bd", "delete this buffer" },
      { "<Leader>t", "toggle a shell in the bottom pane" },
      { "<Esc><Esc>  (terminal)", "leave terminal input mode" },
      { "<Esc>", "clear the search highlight and any multicursors" },
    },
  },
  {
    "TOGGLES  (<Leader>u…)",
    {
      { "uh / ud", "inlay hints / diagnostics" },
      { "uv", "inline diagnostics: cursor line or every line" },
      { "uc", "code lens counts" },
      { "uw / us", "wrap / spelling" },
      { "ul / uL", "line numbers / relative numbers" },
      { "ug / uT", "indent guides / treesitter" },
      { "uS / uD", "smooth scrolling / dim" },
      { "uH", "contextual key hints" },
      { "un / uC", "dismiss notifications / pick a colourscheme (remembered)" },
    },
  },
  {
    "REPEATED EDITS (NO MULTICURSOR)",
    {
      { ".", "repeat the last change" },
      { "cgn{text}<Esc>", "change the next match, then . for each one after" },
      { "n. / N.", "next / previous match, then repeat" },
      { "* / #", "search the word under the cursor forward / backward" },
      { "<C-v> … I / A", "block-select columns, then insert / append on every line" },
      { ":%s/old/new/gc", "replace throughout the buffer, confirming each match" },
      { ":'<,'>normal .", "repeat the last change on every selected line" },
      { "Q", "multicursor; <Esc> clears them" },
    },
  },
  {
    "MACROS",
    {
      { "qa … q", "record keystrokes into register a" },
      { " a  (statusline)", "a recording is running, into register a" },
      { "@a / @@", "play macro a / replay the last one" },
      { "10@a", "play macro a ten times" },
      { "qA … q", "append more keystrokes to macro a" },
      { "<Leader>q", "list the macro registers; ● was recorded this session" },
      { ":reg a", "inspect what was recorded" },
      { ":'<,'>normal @a", "run macro a on every selected line" },
      { ":g/pattern/normal @a", "run macro a on every matching line" },
    },
  },
  {
    "ADVANCED NATIVE TOOLS",
    {
      { "operator + motion", "compose edits: d / c / y with w, %, }, ], f{char}" },
      { 'ciw / ci" / da{', "change a word, quoted text; delete around braces" },
      { "vi{ / va{", "select inside / around braces" },
      { "<C-o> / <C-i>", "jumplist back / forward" },
      { "<Leader>sj / su", "the jumplist / undo history, with preview" },
      { "m<letter> '<letter>", "set and jump to a mark" },
      { "q: / q/", "command and search history as editable buffers" },
      { ":cdo {cmd} | update", "run a command on every quickfix entry" },
      { ":help repeat.txt", "the reference for . macros and :global" },
      { ":help index.txt", "every built-in key; <Leader>sk lists only mappings" },
      { ":Tutor", "interactive Neovim fundamentals" },
    },
  },
}

---@return string[]
local function lines()
  local out = {
    "  What this config adds, plus the native patterns it assumes you use",
    "  instead of a multicursor. :help is still the complete reference.",
  }

  local function section(name, entries)
    vim.list_extend(out, { "", "  " .. name, "" })
    for _, entry in ipairs(entries) do
      -- `%-22s` pads by bytes, so æ ø … and · would shift the second column.
      local pad = math.max(1, 22 - vim.fn.strdisplaywidth(entry[1]))
      out[#out + 1] = "    " .. entry[1] .. string.rep(" ", pad) .. entry[2]
    end
  end

  for _, value in ipairs(SECTIONS) do
    section(value[1], value[2])
  end

  local registry = require "core.actions"
  local ctx = registry.resolve()
  local entries = {}
  for _, action in ipairs(registry.actions(ctx)) do
    entries[#entries + 1] = { action.category or "Inspect", action.label }
  end
  local names = vim.tbl_map(function(provider) return provider.name end, ctx.providers)
  section(("AVAILABLE HERE  [%s]"):format(#names > 0 and table.concat(names, " + ") or "no project detected"), entries)

  vim.list_extend(out, { "", "  q / <Esc> close   ·   / search   ·   <C-d> / <C-u> scroll" })
  return out
end

function M.close()
  if win and vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  win = nil
end

function M.open()
  if win and vim.api.nvim_win_is_valid(win) then return M.close() end

  local content = lines()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "help"

  local width = math.min(94, math.max(58, vim.o.columns - 8))
  local height = math.min(#content, math.floor(vim.o.lines * 0.85))
  win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " Config help ",
    title_pos = "center",
  })
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true

  for index, line in ipairs(content) do
    if line:match "^  [A-Z][A-Z ]" then
      vim.api.nvim_buf_set_extmark(buf, NS, index - 1, 2, { end_col = #line, hl_group = "Title" })
    end
  end

  for _, key in ipairs { "q", "<Esc>", "<F1>" } do
    vim.keymap.set("n", key, M.close, { buffer = buf, nowait = true })
  end
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function() win = nil end,
  })
end

function M.setup()
  for _, mode in ipairs { "n", "x" } do
    vim.keymap.set(mode, "<F1>", M.open, { desc = "Cheatsheet" })
  end
  vim.api.nvim_create_user_command("Cheatsheet", M.open, { desc = "Open the cheatsheet" })
end

return M
