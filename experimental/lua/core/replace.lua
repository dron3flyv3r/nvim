local M = {}

local TITLE = "Replace"
local NS = vim.api.nvim_create_namespace "core_replace"
local MAX_MATCHES = 5000
local DEBOUNCE_MS = 150

---@class core.replace.Settings
---@field case boolean
---@field word boolean
---@field literal boolean
---@field hidden boolean
---@field ignored boolean
---@field include string
---@field exclude string

---@type core.replace.Settings
local DEFAULTS = {
  case = true,
  word = true,
  literal = true,
  hidden = false,
  ignored = false,
  include = "",
  exclude = "",
}

local SWITCHES = {
  { key = "-c", field = "case", label = "Match case" },
  { key = "-w", field = "word", label = "Whole word" },
  { key = "-l", field = "literal", label = "Literal text (off: regex)" },
  { key = "-.", field = "hidden", label = "Hidden files", project = true },
  { key = "-i", field = "ignored", label = "Git-ignored files", project = true },
}

local FILTERS = {
  { key = "=i", field = "include", label = "Include", empty = "every file" },
  { key = "=e", field = "exclude", label = "Exclude", empty = "nothing" },
}

---@class core.replace.Match
---@field start_col integer
---@field end_col integer
---@field replacement? string

---@class core.replace.Line
---@field row integer
---@field text string
---@field matches core.replace.Match[]
---@field skip? boolean

---@class core.replace.File
---@field raw string the path as rg printed it
---@field path string
---@field display string
---@field lines core.replace.Line[]
---@field skip? boolean

---@class core.replace.State
---@field scope "file"|"project"
---@field bufnr? integer
---@field root string
---@field origin integer
---@field panel integer
---@field win integer
---@field find string
---@field replace string
---@field settings core.replace.Settings
---@field files core.replace.File[]
---@field count integer
---@field truncated boolean
---@field searching boolean
---@field error? string
---@field generation integer
---@field job? vim.SystemObj
---@field targets table<integer, { file: core.replace.File, line?: core.replace.Line }>
---@field fields table<string, { row: integer, col: integer }>
---@field skipped table<string, true>

---@type core.replace.State?
local state
local timer

---@param message string
---@param level? integer
local function notify(message, level) vim.notify(message, level or vim.log.levels.INFO, { title = TITLE }) end

local function store_path()
  return vim.fs.joinpath(vim.fn.stdpath "state" --[[@as string]], "replace.json")
end

---@return core.replace.Settings
local function load_settings()
  local settings = vim.deepcopy(DEFAULTS)
  local ok, lines = pcall(vim.fn.readfile, store_path())
  if not ok then return settings end
  local decoded, stored = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not decoded or type(stored) ~= "table" then return settings end
  for field, default in pairs(DEFAULTS) do
    if type(stored[field]) == type(default) then settings[field] = stored[field] end
  end
  return settings
end

---@param settings core.replace.Settings
local function save_settings(settings)
  local path = store_path()
  vim.fs.mkdir(vim.fs.dirname(path), { parents = true })
  pcall(vim.fn.writefile, { vim.json.encode(settings) }, path)
end

---@param text string
---@return string[]
local function globs(text) return vim.split(text, "[,%s]+", { trimempty = true }) end

---@param s core.replace.State
---@param extra string[]
---@return string[]
local function rg_command(s, extra)
  local cmd = { "rg", "--no-config", "--color=never", s.settings.case and "--case-sensitive" or "--ignore-case" }
  if s.settings.word then cmd[#cmd + 1] = "--word-regexp" end
  if s.settings.literal then cmd[#cmd + 1] = "--fixed-strings" end
  if s.scope == "project" then
    if s.settings.hidden then cmd[#cmd + 1] = "--hidden" end
    if s.settings.ignored then cmd[#cmd + 1] = "--no-ignore" end
    cmd[#cmd + 1] = "--glob=!.git"
    for _, glob in ipairs(globs(s.settings.include)) do
      cmd[#cmd + 1] = "--glob=" .. glob
    end
    for _, glob in ipairs(globs(s.settings.exclude)) do
      cmd[#cmd + 1] = "--glob=!" .. glob
    end
  end
  vim.list_extend(cmd, extra)
  vim.list_extend(cmd, { "-e", s.find, s.scope == "file" and "-" or "." })
  return cmd
end

---@param s core.replace.State
---@return string?
local function stdin(s)
  if s.scope ~= "file" then return nil end
  return table.concat(vim.api.nvim_buf_get_lines(s.bufnr, 0, -1, false), "\n") .. "\n"
end

---@param s core.replace.State
---@param raw string
---@return string path
---@return string display
local function resolve(s, raw)
  if s.scope == "file" then
    local path = vim.api.nvim_buf_get_name(s.bufnr)
    return path, vim.fn.fnamemodify(path, ":~:.")
  end
  local relative = raw:gsub("^%./", "")
  return vim.fs.joinpath(s.root, relative), relative
end

---@param file core.replace.File
---@param line? core.replace.Line
---@return string
local function skip_key(file, line) return line and ("%s\0%d\0%s"):format(file.path, line.row, line.text) or file.path end

---@param s core.replace.State
---@param stdout string
local function parse_matches(s, stdout)
  local by_raw = {}
  for line in vim.gsplit(stdout, "\n", { plain = true, trimempty = true }) do
    local ok, event = pcall(vim.json.decode, line)
    local data = ok and event.type == "match" and event.data or nil
    local raw, text = data and data.path.text, data and data.lines.text
    if type(raw) == "string" and type(text) == "string" then
      text = text:gsub("\r?\n$", "")
      local entry = { row = data.line_number - 1, text = text, matches = {} }
      for _, sub in ipairs(data.submatches) do
        if sub["end"] > sub.start and sub["end"] <= #text then
          entry.matches[#entry.matches + 1] = { start_col = sub.start, end_col = sub["end"] }
        end
      end
      if #entry.matches > 0 then
        if s.count + #entry.matches > MAX_MATCHES then
          s.truncated = true
          return
        end
        local file = by_raw[raw]
        if not file then
          local path, display = resolve(s, raw)
          file = { raw = raw, path = path, display = display, lines = {}, skip = s.skipped[path] }
          by_raw[raw] = file
          s.files[#s.files + 1] = file
        end
        entry.skip = s.skipped[skip_key(file, entry)]
        file.lines[#file.lines + 1] = entry
        s.count = s.count + #entry.matches
      end
    end
  end
end

-- Paired by order within a line: with --replace, rg reports each column as
-- measured in the already-replaced line, so the second match on a line is off.
---@param s core.replace.State
---@param stdout string
local function parse_replacements(s, stdout)
  local by_line = {}
  for line in vim.gsplit(stdout, "\n", { plain = true, trimempty = true }) do
    local split = line:find("\0", 1, true) or #line + 1
    local lnum, replacement = line:sub(split + 1):match "^(%d+):%d+:(.*)$"
    if lnum then
      local key = line:sub(1, split - 1) .. ":" .. lnum
      by_line[key] = by_line[key] or {}
      table.insert(by_line[key], replacement)
    end
  end
  for _, file in ipairs(s.files) do
    for _, entry in ipairs(file.lines) do
      local replacements = by_line[file.raw .. ":" .. (entry.row + 1)] or {}
      for index, match in ipairs(entry.matches) do
        match.replacement = replacements[index]
      end
    end
  end
end

---@param s core.replace.State
---@return boolean
local function uses_captures(s) return not s.settings.literal and s.replace:find("$", 1, true) ~= nil end

---@param s core.replace.State
---@param match core.replace.Match
---@return string
local function replacement(s, match) return match.replacement or s.replace end

local render

---@param s core.replace.State
---@param generation integer
---@param result vim.SystemCompleted
---@return boolean
local function settled(s, generation, result)
  if state ~= s or s.generation ~= generation then return false end
  s.job = nil
  if result.code == 2 then
    s.error = vim.trim(result.stderr or ""):match "[^\n]*$"
    s.files, s.count, s.searching = {}, 0, false
    render()
    return false
  end
  return true
end

local function search()
  local s = state
  if not s then return end
  s.generation = s.generation + 1
  local generation = s.generation
  if s.job then s.job:kill(15) end
  s.job, s.files, s.count, s.truncated, s.error = nil, {}, 0, false, nil
  s.searching = s.find ~= ""
  render()
  if not s.searching then return end

  local input = stdin(s)
  local opts = { cwd = s.root, stdin = input, text = true }
  s.job = vim.system(rg_command(s, { "--json" }), opts, function(result)
    vim.schedule(function()
      if not settled(s, generation, result) then return end
      parse_matches(s, result.stdout or "")
      table.sort(s.files, function(a, b) return a.display < b.display end)
      if not uses_captures(s) or s.count == 0 then
        s.searching = false
        return render()
      end
      local extra = { "--only-matching", "--replace=" .. s.replace, "--with-filename", "--null", "-n", "--column" }
      s.job = vim.system(rg_command(s, extra), opts, function(second)
        vim.schedule(function()
          if not settled(s, generation, second) then return end
          parse_replacements(s, second.stdout or "")
          s.searching = false
          render()
        end)
      end)
    end)
  end)
end

local function search_soon()
  if timer then
    timer:stop()
  else
    timer = vim.uv.new_timer()
  end
  timer:start(DEBOUNCE_MS, 0, vim.schedule_wrap(search))
end

---@param s core.replace.State
---@param line core.replace.Line
---@param skipped boolean
---@return string text
---@return table[] highlights
local function preview_line(s, line, skipped)
  local number = ("%6d  "):format(line.row + 1)
  local indent = #line.text:match "^%s*"
  local pieces, highlights, cursor = { number }, { { 0, #number, "LineNr" } }, indent
  local width = #number
  local function push(text, group)
    pieces[#pieces + 1] = text
    if group and text ~= "" then highlights[#highlights + 1] = { width, width + #text, group } end
    width = width + #text
  end
  for _, match in ipairs(line.matches) do
    push(line.text:sub(cursor + 1, match.start_col))
    local old = line.text:sub(match.start_col + 1, match.end_col)
    if skipped then
      push(old, "Search")
    else
      push(old, "DiffDelete")
      push(replacement(s, match), "DiffAdd")
    end
    cursor = match.end_col
  end
  push(line.text:sub(cursor + 1))
  if skipped then table.insert(highlights, 2, { #number, width, "Comment" }) end
  return table.concat(pieces), highlights
end

---@param s core.replace.State
---@return integer included
---@return integer files
local function included(s)
  local count, files = 0, 0
  for _, file in ipairs(s.files) do
    local before = count
    if not file.skip then
      for _, line in ipairs(file.lines) do
        if not line.skip then count = count + #line.matches end
      end
    end
    if count > before then files = files + 1 end
  end
  return count, files
end

---@param s core.replace.State
---@return string text
---@return string group
local function status(s)
  if s.error then return s.error, "ErrorMsg" end
  if s.find == "" then return "Press f to type what to find", "Comment" end
  if s.searching then return "Searching…", "Comment" end
  if s.count == 0 then return "No matches", "Comment" end
  local count, files = included(s)
  local text = ("%d match%s in %d file%s"):format(count, count == 1 and "" or "es", files, files == 1 and "" or "s")
  if count < s.count then text = text .. (", %d skipped"):format(s.count - count) end
  if s.truncated then text = text .. (" (stopped at %d; narrow the search to replace)"):format(MAX_MATCHES) end
  return text, "Title"
end

function render()
  local s = state
  if not s or not vim.api.nvim_buf_is_valid(s.panel) then return end
  local lines, marks = {}, {}
  s.targets, s.fields = {}, {}

  local function add(text, highlights, target)
    lines[#lines + 1] = text
    for _, mark in ipairs(highlights or {}) do
      marks[#marks + 1] = { #lines - 1, mark[1], mark[2], mark[3] }
    end
    if target then s.targets[#lines] = target end
  end
  local function field(name, key, label, value, empty)
    local prefix = ("  %-3s%-9s"):format(key, label)
    s.fields[name] = { row = #lines + 1, col = #prefix }
    local shown = value ~= "" and value or empty
    add(
      prefix .. shown,
      { { 2, 2 + #key, "Special" }, { #prefix, #prefix + #shown, value ~= "" and "String" or "Comment" } }
    )
  end

  local where = s.scope == "file" and vim.fn.fnamemodify(vim.api.nvim_buf_get_name(s.bufnr), ":~:.")
    or vim.fn.fnamemodify(s.root, ":~")
  local heading = s.scope == "file" and " Replace in file  " or " Replace in project  "
  add(heading .. where, { { 0, #heading, "Title" }, { #heading, #heading + #where, "Directory" } })
  add ""
  field("find", "f", "Find", s.find, "nothing yet")
  field("replace", "r", "Replace", s.replace, "nothing: matches are deleted")
  add ""
  add(" Switches", { { 0, -1, "Title" } })
  for _, switch in ipairs(SWITCHES) do
    if s.scope == "project" or not switch.project then
      local on = s.settings[switch.field]
      local text = ("  %-3s %-28s %s"):format(switch.key, switch.label, on and "on" or "off")
      add(text, { { 2, 2 + #switch.key, "Special" }, { #text - (on and 2 or 3), #text, on and "String" or "Comment" } })
    end
  end
  if s.scope == "project" then
    add ""
    add(" Filters  (globs, comma separated)", { { 0, 8, "Title" }, { 8, -1, "Comment" } })
    for _, filter in ipairs(FILTERS) do
      field(filter.field, filter.key, filter.label, s.settings[filter.field], filter.empty)
    end
  end
  add ""
  local legend, highlights = " ", {}
  for _, entry in ipairs { { "R", "replace" }, { "x", "skip" }, { "<CR>", "go to" }, { "q", "close" } } do
    highlights[#highlights + 1] = { #legend, #legend + #entry[1], "Special" }
    legend = legend .. entry[1] .. " " .. entry[2] .. "   "
  end
  add(legend, highlights)
  add ""
  local text, group = status(s)
  add(" " .. text, { { 1, -1, group } })

  for _, file in ipairs(s.files) do
    add ""
    local count = 0
    for _, line in ipairs(file.lines) do
      count = count + #line.matches
    end
    local header = (" %s  %d"):format(file.display, count)
    add(header, { { 1, 1 + #file.display, file.skip and "Comment" or "Directory" } }, { file = file })
    for _, line in ipairs(file.lines) do
      local row_text, row_highlights = preview_line(s, line, file.skip or line.skip or false)
      add(row_text, row_highlights, { file = file, line = line })
    end
  end

  vim.bo[s.panel].modifiable = true
  vim.api.nvim_buf_set_lines(s.panel, 0, -1, false, lines)
  vim.bo[s.panel].modifiable = false
  vim.api.nvim_buf_clear_namespace(s.panel, NS, 0, -1)
  for _, mark in ipairs(marks) do
    local row, first, last, hl = mark[1], mark[2], mark[3], mark[4]
    local length = #lines[row + 1]
    vim.api.nvim_buf_set_extmark(s.panel, NS, row, math.min(first, length), {
      end_col = last < 0 and length or math.min(last, length),
      hl_group = hl,
    })
  end
end

---@param name "find"|"replace"|"include"|"exclude"
local function edit(name)
  local s = state
  if not s or not s.fields[name] or not vim.api.nvim_win_is_valid(s.win) then return end
  local is_setting = name == "include" or name == "exclude"
  local value = is_setting and s.settings[name] or s[name]
  local position = s.fields[name]

  local input = vim.api.nvim_create_buf(false, true)
  vim.bo[input].bufhidden = "wipe"
  vim.b[input].completion = false
  vim.bo[input].filetype = "core_replace_input"
  vim.api.nvim_buf_set_lines(input, 0, -1, false, { value })
  local float = vim.api.nvim_open_win(input, true, {
    relative = "win",
    win = s.win,
    bufpos = { position.row - 1, position.col },
    row = 0,
    col = 0,
    width = math.max(vim.api.nvim_win_get_width(s.win) - position.col - 2, 10),
    height = 1,
    style = "minimal",
    border = "none",
  })

  local function changed()
    local text = vim.api.nvim_buf_get_lines(input, 0, 1, false)[1] or ""
    if is_setting then
      s.settings[name] = text
      save_settings(s.settings)
    else
      s[name] = text
    end
    search_soon()
  end
  local function finish()
    if vim.api.nvim_win_is_valid(float) then vim.api.nvim_win_close(float, true) end
    if vim.api.nvim_win_is_valid(s.win) then vim.api.nvim_set_current_win(s.win) end
  end

  local group = vim.api.nvim_create_augroup("core_replace_input", { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, { group = group, buffer = input, callback = changed })
  vim.api.nvim_create_autocmd({ "InsertLeave", "WinLeave" }, {
    group = group,
    buffer = input,
    once = true,
    callback = function() vim.schedule(finish) end,
  })
  vim.keymap.set("i", "<CR>", "<Esc>", { buffer = input, desc = "Done" })
  vim.cmd "startinsert!"
end

---@param field string
local function toggle(field)
  local s = state
  if not s then return end
  s.settings[field] = not s.settings[field]
  save_settings(s.settings)
  search()
end

---@return { file: core.replace.File, line?: core.replace.Line }?
local function target_under_cursor()
  local s = state
  if not s then return nil end
  return s.targets[vim.api.nvim_win_get_cursor(s.win)[1]]
end

local function skip()
  local target = target_under_cursor()
  if not target then return end
  local item = target.line or target.file
  item.skip = not item.skip
  state.skipped[skip_key(target.file, target.line)] = item.skip or nil
  render()
end

---@param s core.replace.State
---@return integer
local function editing_window(s)
  if vim.api.nvim_win_is_valid(s.origin) and s.origin ~= s.win then return s.origin end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if win ~= s.win and vim.api.nvim_win_get_config(win).relative == "" then return win end
  end
  vim.cmd "leftabove vsplit"
  return vim.api.nvim_get_current_win()
end

local function jump()
  local s, target = state, target_under_cursor()
  if not s or not target then return end
  local line = target.line or target.file.lines[1]
  local win = editing_window(s)
  s.origin = win
  vim.api.nvim_set_current_win(win)
  if s.scope == "file" then
    vim.api.nvim_win_set_buf(win, s.bufnr)
  else
    vim.cmd.edit(vim.fn.fnameescape(target.file.path))
  end
  pcall(vim.api.nvim_win_set_cursor, win, { line.row + 1, line.matches[1].start_col })
  vim.cmd "normal! zz"
end

---@param s core.replace.State
---@param file core.replace.File
---@param bufnr integer
---@return integer replaced
---@return integer stale
local function apply_file(s, file, bufnr)
  local replaced, stale = 0, 0
  for _, line in ipairs(file.lines) do
    if not line.skip then
      local current = vim.api.nvim_buf_get_lines(bufnr, line.row, line.row + 1, false)[1]
      if current ~= line.text then
        stale = stale + 1
      else
        for index = #line.matches, 1, -1 do
          local match = line.matches[index]
          local text = vim.split(replacement(s, match), "\n", { plain = true })
          vim.api.nvim_buf_set_text(bufnr, line.row, match.start_col, line.row, match.end_col, text)
          replaced = replaced + 1
        end
      end
    end
  end
  return replaced, stale
end

---@param bufnr integer
---@return boolean
local function writable(bufnr) return vim.bo[bufnr].modifiable and not vim.bo[bufnr].readonly end

local function close()
  local s = state
  if s and vim.api.nvim_buf_is_valid(s.panel) then vim.api.nvim_buf_delete(s.panel, { force = true }) end
end

local function apply()
  local s = state
  if not s then return end
  if s.searching then return notify "Still searching" end
  if s.truncated then return notify("Too many matches to replace safely; narrow the search", vim.log.levels.WARN) end
  if included(s) == 0 then return notify "Nothing to replace" end

  local replaced, touched, stale, refused = 0, 0, 0, {}
  for _, file in ipairs(s.files) do
    if not file.skip then
      local existed = s.scope == "file" or vim.fn.bufexists(file.path) == 1
      local bufnr = s.bufnr or vim.fn.bufadd(file.path)
      local was_loaded = vim.api.nvim_buf_is_loaded(bufnr)
      -- Loaded without autocommands so that a project-wide replace does not start
      -- a language server, a formatter or editorconfig for every file it touches.
      if not was_loaded then vim.cmd(("noautocmd call bufload(%d)"):format(bufnr)) end
      if writable(bufnr) then
        local count, out_of_date = apply_file(s, file, bufnr)
        replaced, stale = replaced + count, stale + out_of_date
        if count > 0 then touched = touched + 1 end
        if not was_loaded and count > 0 then
          vim.api.nvim_buf_call(bufnr, function() vim.cmd "noautocmd silent update" end)
        end
      else
        refused[#refused + 1] = file.display
      end
      if not was_loaded then vim.api.nvim_buf_delete(bufnr, { force = true, unload = existed }) end
    end
  end

  local message = ("Replaced %d match%s in %d file%s"):format(
    replaced,
    replaced == 1 and "" or "es",
    touched,
    touched == 1 and "" or "s"
  )
  local level = vim.log.levels.INFO
  if stale > 0 then
    message = message
      .. ("\n%d line%s changed since the preview and were left alone"):format(stale, stale == 1 and "" or "s")
    level = vim.log.levels.WARN
  end
  if #refused > 0 then
    message = message .. "\nRead-only or held by a review: " .. table.concat(refused, ", ")
    level = vim.log.levels.WARN
  end
  notify(message, level)
  close()
end

---@param s core.replace.State
local function open_panel(s)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "core_replace"
  local win = vim.api.nvim_open_win(buf, true, {
    split = "right",
    win = -1,
    width = math.max(60, math.floor(vim.o.columns * 0.45)),
  })
  for option, value in pairs {
    number = false,
    relativenumber = false,
    signcolumn = "no",
    foldcolumn = "0",
    statuscolumn = "",
    wrap = false,
    list = false,
    spell = false,
    winfixwidth = true,
  } do
    vim.api.nvim_set_option_value(option, value, { win = win, scope = "local" })
  end
  s.panel, s.win = buf, win

  local function map(lhs, fn, desc) vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = desc }) end
  map("f", function() edit "find" end, "Edit what to find")
  map("r", function() edit "replace" end, "Edit the replacement")
  map("R", apply, "Replace every match that is not skipped")
  map("x", skip, "Skip this line or file")
  map("<CR>", jump, "Go to this match")
  map("q", close, "Close")
  for _, switch in ipairs(SWITCHES) do
    if s.scope == "project" or not switch.project then
      map(switch.key, function() toggle(switch.field) end, switch.label)
    end
  end
  if s.scope == "project" then
    for _, filter in ipairs(FILTERS) do
      map(filter.key, function() edit(filter.field) end, filter.label .. " globs")
    end
  end

  local group = vim.api.nvim_create_augroup("core_replace", { clear = true })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = buf,
    callback = function()
      if state and state.job then state.job:kill(15) end
      state = nil
    end,
  })
  vim.api.nvim_create_autocmd("BufEnter", { group = group, buffer = buf, callback = search_soon })
end

---@return string
local function initial_find()
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" then
    local region = vim.fn.getregion(vim.fn.getpos "v", vim.fn.getpos ".", { type = mode })
    vim.api.nvim_feedkeys(vim.keycode "<Esc>", "nx", false)
    return region[1] or ""
  end
  return vim.fn.expand "<cword>"
end

---@param scope "file"|"project"
function M.open(scope)
  if vim.fn.executable "rg" == 0 then return notify("ripgrep (rg) is not installed", vim.log.levels.ERROR) end
  local bufnr = vim.api.nvim_get_current_buf()
  if scope == "file" and vim.bo[bufnr].buftype ~= "" then
    return notify("Replace in file needs a file buffer", vim.log.levels.WARN)
  end
  local find = initial_find()
  close()

  local cwd = vim.fn.getcwd()
  ---@type core.replace.State
  local s = {
    scope = scope,
    bufnr = scope == "file" and bufnr or nil,
    root = scope == "file" and cwd or (vim.fs.root(cwd, ".git") or cwd),
    origin = vim.api.nvim_get_current_win(),
    panel = -1,
    win = -1,
    find = find,
    replace = "",
    settings = load_settings(),
    files = {},
    count = 0,
    truncated = false,
    searching = false,
    generation = 0,
    targets = {},
    fields = {},
    skipped = {},
  }
  state = s
  open_panel(s)
  search()
  edit(find == "" and "find" or "replace")
end

return M
