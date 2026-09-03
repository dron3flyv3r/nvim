-- Compact help for this configuration's additions plus a small set of native
-- workflows that replace common IDE/multicursor habits. :help remains the
-- complete reference.
local M = {}
local NS = vim.api.nvim_create_namespace "user_cheatsheet"
local win

local STATIC = {
  {
    "PROJECT ACTIONS",
    {
      { "<Leader>ra", "actions valid in this project" },
      { "<Leader>Up / Us / Ur", "Unity play / stop / restart" },
      { "<Leader>Ub / Ut / Ua", "Unity refresh / test / attach" },
      { "<Leader>Ue / Uw / Ul", "Unity errors / warnings / log" },
      { "<Leader>Rr / Rt / Rd", "Rust run / test / debug" },
      { "<Leader>Rb / Re / Rx", "Rust build / explain / expand macro" },
      { ":ContextStatus", "explain detected providers and missing tools" },
    },
  },
  {
    "DANISH ALIASES",
    {
      { "ø / æ", "[ / ] prefixes" },
      { "Ø / Æ", "{ / } motions" },
      { "å / Å", "$ / ^ motions" },
      { "æb / øb", "next / previous buffer" },
      { "æd / ød", "next / previous diagnostic" },
      { "æq / øq", "next / previous quickfix item" },
    },
  },
  {
    "CUSTOM SURFACES",
    {
      { "<F1>", "this help" },
      { "<Leader>ff / fw", "find files / search project" },
      { "<Leader>xx / xX", "workspace / buffer diagnostics" },
      { "<Leader>gd", "review repository diff" },
      { "<Leader>sm / sw", "zoom split / pick window" },
      { "<Leader>T…", "tab-page operations" },
      { "<Leader>a…", "AI tools" },
      { "<F7>", "toggle terminal" },
      { "<Leader>uW", "toggle leave/focus autosave" },
    },
  },
  {
    "COLLABORATION",
    {
      { "<Leader>Ch / Cj", "host this project / join with invitation code" },
      { "<Leader>Cy", "copy the active invitation code" },
      { "<Leader>Cp / Cf", "jump to / follow a peer cursor" },
      { "<Leader>Cs / Ci", "stop sharing / connection information" },
      { "<Leader>Cl", "Teamtype daemon log" },
    },
  },
  {
    "READING ERRORS & DOCS",
    {
      { "gl / <Leader>ld", "full error on this line; press again to focus and scroll" },
      { "<Leader>xx / xX", "browse project / current-buffer diagnostics with preview" },
      { "æd / ød", "next / previous diagnostic" },
      { "K", "documentation for symbol under cursor; press again to focus" },
      { "q", "close a focused error or documentation popup" },
    },
  },
  {
    "AI EXPLANATIONS",
    {
      { "<Leader>ae", "explain current line or visual selection" },
      { "<Leader>aE", "teach current line or selection in depth" },
      { "<Leader>at", "open the last explanation as a conversation" },
      { "q / <Esc>", "close the explanation popup; the conversation is retained" },
    },
  },
  {
    "NATIVE FIRST",
    {
      { "?", "backward search (unchanged)" },
      { "<C-o> / <C-i>", "jumplist back / forward" },
      { "[b / ]b", "previous / next buffer" },
      { "grn / gra", "LSP rename / code action" },
      { ":Tutor", "interactive Neovim fundamentals" },
      { ":help <topic>", "the complete reference" },
    },
  },
  {
    "REPEATED EDITS (NO MULTICURSOR)",
    {
      { ".", "repeat the last change" },
      { "n. / N.", "next / previous match, then repeat change" },
      { "* / #", "search word under cursor forward / backward" },
      { "cgn{text}<Esc>", "change the next search match; press . for the rest" },
      { "<C-v> … I/A", "block-select columns; insert/append on every selected line" },
      { ":%s/old/new/gc", "replace throughout buffer, confirming each match" },
      { ":'<,'>normal .", "repeat last change on every visually selected line" },
    },
  },
  {
    "MACROS",
    {
      { "qa … q", "record keystrokes into register a; q stops recording" },
      { "@a / @@", "play macro a / replay the last macro" },
      { "10@a", "play macro a ten times" },
      { "qA … q", "append more keystrokes to macro a" },
      { ":reg a", "inspect register a and its recorded macro" },
      { ":'<,'>normal @a", "run macro a once on every selected line" },
      { ":g/pattern/normal @a", "run macro a on every matching line" },
    },
  },
  {
    "ADVANCED NATIVE TOOLS",
    {
      { "operator + motion", "compose edits: d/c/y with w, %, }, ], f{char}, etc." },
      { 'ciw / ci" / da{', "change word / quoted text; delete around braces" },
      { "vi{ / va{", "select inside / around braces" },
      { "ma / `a / 'a", "set mark a; jump exactly / jump to its line" },
      { "q: / q/", "edit command history / search history as normal buffers" },
      { ":cdo {cmd} | update", "apply a command to every quickfix entry" },
      { ":argdo {cmd} | update", "apply a command to every argument-list file" },
      { ":help repeat.txt", "reference for ., macros, substitutions and :global" },
    },
  },
}

local function lines()
  local out = {
    "  Config additions plus native patterns for efficient repeated edits.",
    "  Nothing below changes Neovim's motions, operators, registers or macros.",
  }
  local function section(name, entries)
    vim.list_extend(out, { "", "  " .. name, "" })
    for _, entry in ipairs(entries) do
      table.insert(out, ("    %-22s%s"):format(entry[1], entry[2]))
    end
  end
  for _, value in ipairs(STATIC) do
    section(value[1], value[2])
  end

  local context = require "user.context"
  local ctx = context.resolve()
  local entries = {}
  for _, action in ipairs(context.actions(ctx)) do
    table.insert(entries, { action.category, action.label })
  end
  local names = vim.tbl_map(function(provider) return provider.name end, ctx.providers)
  section("AVAILABLE HERE  [" .. (#names > 0 and table.concat(names, " + ") or "no project context") .. "]", entries)
  vim.list_extend(out, { "", "  q / <Esc> close   ·   / search   ·   <C-d>/<C-u> scroll" })
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
  vim.api.nvim_buf_add_highlight(buf, NS, "Title", 3, 2, -1)
  for index, line in ipairs(content) do
    if line:match "^  [A-Z][A-Z ]" then vim.api.nvim_buf_add_highlight(buf, NS, "Title", index - 1, 2, -1) end
  end
  for _, key in ipairs { "q", "<Esc>", "<F1>" } do
    vim.keymap.set("n", key, M.close, { buffer = buf, nowait = true })
  end
  vim.api.nvim_create_autocmd(
    "WinClosed",
    { pattern = tostring(win), once = true, callback = function() win = nil end }
  )
end

return M
