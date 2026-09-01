--- Per-project suppression of individual inlay hints.
---
--- `plugins/astrolsp.lua` turns inlay hints on for every server that offers
--- them, and AstroNvim's `<Leader>uH` turns them off for a buffer. Between
--- "every hint" and "no hints" there is nothing, and the protocol is the reason:
--- `textDocument/inlayHint` answers with a flat array of `{ position, label }`
--- and says nothing about which call each entry belongs to. Servers expose
--- category switches -- all literal arguments, suppress when the argument name
--- already matches the parameter -- and no server exposes "not this one".
---
--- So the narrowing happens here, on the client, between the response arriving
--- and Neovim drawing it. Two things can be suppressed:
---
---   * a CALLEE by name. `HelpNumberDecorator` in the list means no `number:`,
---     `onClick:` or `content:` at any call site.
---   * a PATH by prefix or glob. Generated code, one noisy file, or -- with
---     `**` -- everything.
---
--- ── WHERE THE LISTS LIVE ────────────────────────────────────────────────────
---
--- One file, `inlay-hints.json` under `stdpath("data")`, holding every
--- project's lists keyed by project root, plus a `global` bucket that applies
--- everywhere. Nothing is ever written into the projects themselves.
---
--- The cost of a central store is that it is keyed by a path, and a path can
--- change: rename a checkout and its entry is orphaned rather than followed.
--- That is visible rather than silent -- the hints come back, `:InlayHintsIgnored`
--- shows an empty list, and re-ignoring is one keypress -- and `write_store`
--- drops buckets as they empty so the file does not accumulate the dead ones.
--- See `read_store` for the format.
---
--- ── WHERE THE FILTER HOOKS IN ───────────────────────────────────────────────
---
--- `vim.lsp.handlers["textDocument/inlayHint"]`, wrapped. That table is the
--- fallback half of `Client:_resolve_handler`, which is
---
---     return self.handlers[method] or lsp.handlers[method]
---
--- (`runtime/lua/vim/lsp/client.lua:656` on 0.12.2) and is consulted when the
--- response arrives, not when the client is created. So the wrap catches
--- servers that started before this module loaded, and no server in this config
--- sets a per-client `handlers` entry for the method that would shadow it.
---
--- Filtering here rather than at the drawing layer means the hidden hints never
--- enter `bufstate.client_hints`: `vim.lsp.inlay_hint.get()` will not see them,
--- and un-ignoring something has to re-ask the server. `M.refresh` does that.
---
--- ── FINDING THE CALLEE ──────────────────────────────────────────────────────
---
--- A hint carries a position and nothing else, so the call it belongs to has to
--- come from the syntax tree. The rule is: from the hint's position, walk UP to
--- the first `argument_list` ancestor; its parent is the call; the text between
--- the call's start and the argument list's start is the callee.
---
--- Upward, and not "the node at the position", because of nesting. Parsing
---
---     new HelpNumberDecorator(2, something, new Input())
---
--- with the C# grammar puts the `content:` hint at column 50, which is exactly
--- where the inner `object_creation_expression` for `Input` begins -- asking
--- what node is at that position answers `Input`, the wrong call. Measured:
---
---     object_creation_expression { 2, 12, 2, 62 }   <- HelpNumberDecorator
---       identifier               { 2, 16, 2, 35 }
---       argument_list            { 2, 35, 2, 62 }
---         argument               { 2, 36, 2, 37 }   <- "number:" hint
---         argument               { 2, 39, 2, 48 }   <- "onClick:" hint
---         argument               { 2, 50, 2, 61 }   <- "content:" hint
---           object_creation_expression { 2, 50, 2, 61 }   <- Input
---             argument_list      { 2, 59, 2, 61 }
---
--- Walking up from column 50 leaves `Input`'s own argument list below and to
--- the right (it starts at column 59) and reaches HelpNumberDecorator's first,
--- which is the answer wanted. The hints on `Input`'s own arguments, if it had
--- any, would start inside that inner list and resolve to `Input`.
---
--- Reading the callee as buffer TEXT rather than through a named field keeps
--- this grammar-agnostic: C# reaches the name through `object_creation_expression`
--- and `invocation_expression`, Python through `call`, C++ and Rust through
--- `call_expression`, and every one of them puts the callee immediately before
--- its argument list. `normalize` strips the parts that are not the name.

local M = {}

--- Every project's lists, in one file outside every project.
local STORE = vim.fs.joinpath(vim.fn.stdpath "data" --[[@as string]], "inlay-hints.json")

--- What counts as a project, for keying purposes only -- nothing is read from
--- or written to the root itself.
local ROOT_MARKERS = { ".git", ".hg", ".svn" }

--- The key the `global` bucket is compiled under. A byte no path contains.
local GLOBAL = "\0"

--- Grammar node types that hold a call's arguments. One flat set rather than a
--- table per language: the names barely vary, and a filetype this config never
--- sees is better served by a lucky hit than by an entry nobody maintains.
local ARGUMENT_LISTS = {
  argument_list = true, -- c_sharp, python, c, cpp
  arguments = true, -- rust, lua
  bracketed_argument_list = true, -- c_sharp indexers
}

---@param message string
---@param level integer?
local function notify(message, level) vim.notify(message, level or vim.log.levels.INFO, { title = "Inlay hints" }) end

--- The project root for a buffer, or nil when there is nothing to key on --
--- an unnamed scratch buffer, a `fugitive://` URL, a file outside any project.
--- A nil root is not an error: the `global` bucket still applies.
---@param bufnr integer
---@return string?
local function root_for(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" or name:find "://" then return nil end
  local root = vim.fs.root(bufnr, ROOT_MARKERS)
  return root and vim.fs.normalize(root) or nil
end

---@class user.inlay_hints.Bucket
---@field callees string[]
---@field paths string[]

---@class user.inlay_hints.Store
---@field global user.inlay_hints.Bucket
---@field projects table<string, user.inlay_hints.Bucket>

---@type { mtime: integer, data: user.inlay_hints.Store }?
local store_cache = nil

--- Declared up here, beside the store it is derived from, because `write_store`
--- below has to invalidate it. `user.inlay_hints.Rules` is defined with the
--- function that builds it.
---@type { mtime: integer, rules: table<string, user.inlay_hints.Rules> }?
local rules_cache = nil

---@return user.inlay_hints.Bucket
local function empty_bucket() return { callees = {}, paths = {} } end

--- Coerce whatever is on disk into the shape the rest of the file assumes.
---@param value any
---@return user.inlay_hints.Bucket
local function to_bucket(value)
  local bucket = empty_bucket()
  if type(value) ~= "table" then return bucket end
  for _, field in ipairs { "callees", "paths" } do
    for _, entry in ipairs(value[field] or {}) do
      if type(entry) == "string" and entry ~= "" then table.insert(bucket[field], entry) end
    end
  end
  return bucket
end

--- Read the store, cached on mtime.
---
--- The file is buckets of two string arrays and nothing else, because it is
--- meant to be hand-edited (`:InlayHintsEdit`) as often as it is written by
--- `:InlayHintsIgnore`:
---
---     {
---       "global": {
---         "callees": ["Mathf.Lerp"],
---         "paths": ["**/*.g.cs"]
---       },
---       "projects": {
---         "/home/you/git/some_project": {
---           "callees": ["HelpNumberDecorator"],
---           "paths": ["Assets/Generated"]
---         }
---       }
---     }
---
--- A callee matches on either its full text (`Mathf.Lerp`) or its last segment
--- (`Lerp`), so both spellings do what they look like they do. A path with no
--- glob metacharacter in it is a PREFIX -- `Assets/Generated` covers the
--- directory and everything under it -- and anything with `*`, `?`, `[` or `{`
--- is an LSP glob. Both are tried against the project-relative path AND the
--- absolute one, so a `global` pattern can name either and a project pattern
--- reads as the short thing you would type. `**` alone means "no inlay hints".
---
--- A malformed file is reported and then treated as empty: the failure mode of
--- a hint filter has to be showing a hint you did not want, not silently hiding
--- one you did.
---@return user.inlay_hints.Store
local function read_store()
  local stat = vim.uv.fs_stat(STORE)
  local mtime = stat and stat.mtime.sec or 0
  if store_cache and store_cache.mtime == mtime then return store_cache.data end

  ---@type user.inlay_hints.Store
  local data = { global = empty_bucket(), projects = {} }

  local fd = stat and io.open(STORE, "r")
  if fd then
    local text = fd:read "a"
    fd:close()
    local ok, decoded = pcall(vim.json.decode, text)
    if not ok or type(decoded) ~= "table" then
      notify(STORE .. " is not valid JSON, so no hints are being filtered:\n" .. tostring(decoded), vim.log.levels.WARN)
    else
      data.global = to_bucket(decoded.global)
      if type(decoded.projects) == "table" then
        for root, bucket in pairs(decoded.projects) do
          if type(root) == "string" then data.projects[vim.fs.normalize(root)] = to_bucket(bucket) end
        end
      end
    end
  end

  store_cache = { mtime = mtime, data = data }
  return data
end

--- Write the store back, sorted and indented, because this file is read by
--- people. `vim.json.encode` gives one long line, so only the leaf strings go
--- through it -- for the escaping, not the layout.
---
--- Empty buckets are dropped on the way out. That is what keeps the file from
--- filling up with projects that have been renamed, moved or deleted since.
---@param data user.inlay_hints.Store
---@return boolean written
local function write_store(data)
  local function array(list, indent)
    if #list == 0 then return "[]" end
    local sorted = vim.deepcopy(list)
    table.sort(sorted)
    local items = vim.tbl_map(function(value) return indent .. "  " .. vim.json.encode(value) end, sorted)
    return "[\n" .. table.concat(items, ",\n") .. "\n" .. indent .. "]"
  end

  local function bucket(value, indent)
    return table.concat({
      "{",
      indent .. '  "callees": ' .. array(value.callees, indent .. "  ") .. ",",
      indent .. '  "paths": ' .. array(value.paths, indent .. "  "),
      indent .. "}",
    }, "\n")
  end

  local roots = {}
  for root, value in pairs(data.projects) do
    if #value.callees > 0 or #value.paths > 0 then table.insert(roots, root) end
  end
  table.sort(roots)

  local projects = {}
  for _, root in ipairs(roots) do
    table.insert(projects, "    " .. vim.json.encode(root) .. ": " .. bucket(data.projects[root], "    "))
  end

  local text = table.concat({
    "{",
    '  "global": ' .. bucket(data.global, "  ") .. ",",
    '  "projects": ' .. (#projects == 0 and "{}" or "{\n" .. table.concat(projects, ",\n") .. "\n  }"),
    "}",
    "",
  }, "\n")

  vim.fn.mkdir(vim.fs.dirname(STORE), "p")
  local fd = io.open(STORE, "w")
  if not fd then
    notify("Could not write " .. STORE, vim.log.levels.ERROR)
    return false
  end
  fd:write(text)
  fd:close()

  -- The mtime checks in `read_store` and `rules_for` would usually catch this
  -- on their own; dropping BOTH caches makes the next read unconditional, which
  -- matters on a filesystem whose mtime has one-second resolution -- two edits
  -- inside the same second would otherwise leave the compiled rules stale.
  store_cache = nil
  rules_cache = nil
  return true
end

---@class user.inlay_hints.Rules
---@field callees table<string, true> membership test used by the filter
---@field paths { text: string, glob: vim.lpeg.Pattern? }[]
---@field empty boolean nothing to do, so skip everything

--- The global bucket merged with one project's, compiled for matching.
---@param root string?
---@return user.inlay_hints.Rules
local function rules_for(root)
  local stat = vim.uv.fs_stat(STORE)
  local mtime = stat and stat.mtime.sec or 0
  if not rules_cache or rules_cache.mtime ~= mtime then rules_cache = { mtime = mtime, rules = {} } end

  local key = root or GLOBAL
  local cached = rules_cache.rules[key]
  if cached then return cached end

  local data = read_store()
  ---@type user.inlay_hints.Rules
  local rules = { callees = {}, paths = {}, empty = true }

  for _, source in ipairs { data.global, root and data.projects[root] or nil } do
    for _, name in ipairs(source.callees) do
      rules.callees[name] = true
    end
    for _, pattern in ipairs(source.paths) do
      local entry = { text = pattern }
      if pattern:find "[%*%?%[{]" then
        -- `to_lpeg` raises on a malformed glob. One bad line should cost that
        -- line, not the file.
        local ok, compiled = pcall(vim.glob.to_lpeg, pattern)
        if ok then
          entry.glob = compiled
        else
          notify(("Ignoring the unparseable path pattern %q"):format(pattern), vim.log.levels.WARN)
          entry = nil
        end
      end
      if entry then table.insert(rules.paths, entry) end
    end
  end
  rules.empty = next(rules.callees) == nil and #rules.paths == 0

  rules_cache.rules[key] = rules
  return rules
end

--- Collapse a callee expression to the name a person would type.
---@param text string
---@return string? full e.g. `Mathf.Lerp`
---@return string? last e.g. `Lerp`
local function normalize(text)
  text = text:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
  text = text:gsub("^new%s+", "") -- C# / C++ object creation
  text = text:gsub("<.->$", "") -- Foo<T> -> Foo
  text = text:gsub("[!%s]+$", "") -- Rust `println!` -> println
  if text == "" then return nil end
  return text, text:match "[%w_]+$"
end

--- The callee of the call surrounding a position. See the header for the walk.
---@param bufnr integer
---@param row integer 0-indexed
---@param col integer 0-indexed, BYTES
---@param from_cursor boolean? also accept a position on the callee itself
---@return string? full
---@return string? last
local function call_at(bufnr, row, col, from_cursor)
  -- `vim.treesitter.get_node` READS a tree; it does not build one. On a buffer
  -- whose parser exists but has never run it answers nil (measured on 0.12.2),
  -- which would silently switch every callee rule off. So force the parse here
  -- rather than rely on the caller having done it: re-parsing an up-to-date
  -- tree measures 0.17us against get_node's 2.9us on the same buffer, which is
  -- not worth a coupling comment.
  local parser_ok, parser = pcall(vim.treesitter.get_parser, bufnr, nil, { error = false })
  if not parser_ok or not parser or not pcall(parser.parse, parser) then return nil end

  local ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr, pos = { row, col } })
  if not ok then return nil end

  ---@param call TSNode?
  ---@param arguments TSNode
  local function name_between(call, arguments)
    if not call then return nil end
    local srow, scol = call:start()
    local erow, ecol = arguments:start()
    if srow > erow or (srow == erow and scol >= ecol) then return nil end
    local text = table.concat(vim.api.nvim_buf_get_text(bufnr, srow, scol, erow, ecol, {}), " ")
    return normalize(text)
  end

  while node do
    if ARGUMENT_LISTS[node:type()] then return name_between(node:parent(), node) end
    -- Hints always sit inside the argument list, so this second branch is for
    -- the cursor only: `<Leader>lH` with the cursor on the function's own name
    -- should mean the obvious thing rather than "not inside a call".
    if from_cursor then
      for child in node:iter_children() do
        if ARGUMENT_LISTS[child:type()] then return name_between(node, child) end
      end
    end
    node = node:parent()
  end
end

---@param label string|lsp.InlayHintLabelPart[]
---@return string
local function label_text(label)
  if type(label) == "string" then return label end
  return table.concat(vim.tbl_map(function(part) return part.value or "" end, label))
end

--- Is this a parameter-name hint (`number:`) rather than a type hint
--- (`: string`)?
---
--- `kind` is optional in the protocol. When a server omits it the punctuation
--- still separates the two: a parameter hint ends in a colon, a type hint
--- begins with one.
---@param hint lsp.InlayHint
---@return boolean
local function is_parameter_hint(hint)
  if hint.kind == 2 then return true end -- lsp.InlayHintKind.Parameter
  if hint.kind == 1 then return false end -- lsp.InlayHintKind.Type
  return label_text(hint.label):match ":%s*$" ~= nil
end

--- Both spellings of a buffer's path, for `path_ignored`.
---@param bufnr integer
---@param root string?
---@return string absolute
---@return string? relative
local function paths_of(bufnr, root)
  local absolute = vim.fs.normalize(vim.api.nvim_buf_get_name(bufnr))
  return absolute, root and vim.fs.relpath(root, absolute) or nil
end

---@param rules user.inlay_hints.Rules
---@param absolute string
---@param relative string?
---@return boolean
local function path_ignored(rules, absolute, relative)
  -- Built rather than written as `{ relative, absolute }`: `relative` is nil
  -- outside a project, and `ipairs` would stop on it and never reach the
  -- absolute path.
  local candidates = { absolute }
  if relative then table.insert(candidates, 1, relative) end

  for _, entry in ipairs(rules.paths) do
    for _, candidate in ipairs(candidates) do
      if entry.glob then
        if vim.lpeg.match(entry.glob, candidate) then return true end
      elseif candidate == entry.text or candidate:sub(1, #entry.text + 1) == entry.text .. "/" then
        return true
      end
    end
  end
  return false
end

--- Drop the hints this project does not want. The wrapped handler's whole job.
---@param result lsp.InlayHint[]
---@param ctx lsp.HandlerContext
---@return lsp.InlayHint[]
function M.filter(result, ctx)
  local bufnr = ctx.bufnr
  if not bufnr or not vim.api.nvim_buf_is_loaded(bufnr) then return result end

  local root = root_for(bufnr)
  local rules = rules_for(root)
  if rules.empty then return result end

  -- Path rules first. They answer for the whole buffer, so a suppressed file
  -- costs a handful of glob tests instead of a tree descent per hint.
  if #rules.paths > 0 and path_ignored(rules, paths_of(bufnr, root)) then return {} end

  if next(rules.callees) == nil then return result end

  -- No parser means no callee, which means nothing to match on: show the hints.
  -- This is the case in a buffer past `large_buf` in `plugins/astrocore.lua`,
  -- where treesitter is off by design. `call_at` checks this too; doing it once
  -- here keeps a whole response from entering the loop to fail hint by hint.
  local parser_ok, parser = pcall(vim.treesitter.get_parser, bufnr, nil, { error = false })
  if not parser_ok or not parser then return result end

  local client = vim.lsp.get_client_by_id(ctx.client_id)
  local encoding = client and client.offset_encoding or "utf-16"

  local kept, lines = {}, {}
  for _, hint in ipairs(result) do
    local keep = true
    if is_parameter_hint(hint) then
      local lnum = hint.position.line
      if lines[lnum] == nil then lines[lnum] = vim.api.nvim_buf_get_lines(bufnr, lnum, lnum + 1, false)[1] or "" end

      -- The response is still in the SERVER's encoding here; the handler we
      -- wrap converts `hint.position.character` to bytes after we hand it back.
      -- Treesitter needs bytes now, so convert into a local and leave the hint
      -- alone -- converting it twice would shift every hint on a line with a
      -- non-ASCII character in it.
      local col_ok, col = pcall(vim.str_byteindex, lines[lnum], encoding, hint.position.character, false)
      if col_ok then
        local full, last = call_at(bufnr, lnum, col)
        if full and (rules.callees[full] or (last and rules.callees[last])) then keep = false end
      end
    end
    if keep then kept[#kept + 1] = hint end
  end
  return kept
end

--- Re-ask every server that is currently showing hints.
---
--- Needed because the filter drops hints before they reach `bufstate`, so
--- un-ignoring a name cannot be undone from anything the client still holds.
--- `enable(false)` clears the extmarks and `enable(true)` resets the buffer
--- state and re-requests (`_enable` -> `refresh`, runtime
--- `lua/vim/lsp/inlay_hint.lua:258` on 0.12.2). Buffers where hints are already
--- off are left alone, so this never undoes a `<Leader>uH`.
function M.refresh()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.lsp.inlay_hint.is_enabled { bufnr = bufnr } then
      vim.lsp.inlay_hint.enable(false, { bufnr = bufnr })
      vim.lsp.inlay_hint.enable(true, { bufnr = bufnr })
    end
  end
end

--- The bucket an edit should land in, and a name for it.
---@param global boolean?
---@return user.inlay_hints.Store? data
---@return user.inlay_hints.Bucket? bucket
---@return string? scope
local function target(global)
  local data = read_store()
  if global then return data, data.global, "everywhere" end

  local root = root_for(vim.api.nvim_get_current_buf())
  if not root then
    notify(
      "This buffer is not in a project. Add `!` to the command to hide it everywhere instead.",
      vim.log.levels.WARN
    )
    return nil
  end
  data.projects[root] = data.projects[root] or empty_bucket()
  return data, data.projects[root], root
end

---@param bucket user.inlay_hints.Bucket
---@param field "callees"|"paths"
---@param value string
---@param data user.inlay_hints.Store
---@param scope string
---@param what string
local function add(bucket, field, value, data, scope, what)
  if vim.tbl_contains(bucket[field], value) then
    notify(value .. " is already ignored")
    return
  end
  table.insert(bucket[field], value)
  if write_store(data) then
    notify(("%s %s (%s)"):format(what, value, scope))
    M.refresh()
  end
end

--- Stop showing parameter hints for a callee. With no name, the one under the
--- cursor -- on the arguments or on the callee itself.
---@param name string?
---@param global boolean? apply in every project rather than this one
function M.ignore(name, global)
  if not name or name == "" then
    local row, col = unpack(vim.api.nvim_win_get_cursor(0))
    local full, last = call_at(vim.api.nvim_get_current_buf(), row - 1, col, true)
    -- The short name is the useful default: `Lerp` reads better than
    -- `Mathf.Lerp` and both are accepted on the way back in.
    name = last or full
    if not name then
      notify("The cursor is not on a call, so there is no name to ignore", vim.log.levels.WARN)
      return
    end
  end

  local data, bucket, scope = target(global)
  if data and bucket and scope then add(bucket, "callees", name, data, scope, "Hiding parameter hints for") end
end

--- Stop showing any hints for a path. With no argument, the current file --
--- relative to the project root, or absolute when writing to `global`.
---@param pattern string?
---@param global boolean?
function M.ignore_file(pattern, global)
  local data, bucket, scope = target(global)
  if not data or not bucket or not scope then return end

  if not pattern or pattern == "" then
    local bufnr = vim.api.nvim_get_current_buf()
    -- Spelled out rather than as `global and nil or root_for(bufnr)`, which
    -- cannot work: in Lua the `nil` branch of `a and nil or b` always falls
    -- through to `b`, so a global entry would be written project-relative and
    -- then never match anything outside this project.
    local against = nil
    if not global then against = root_for(bufnr) end

    local absolute, relative = paths_of(bufnr, against)
    pattern = relative or absolute
    if pattern == "" then
      notify("This buffer has no file to ignore", vim.log.levels.WARN)
      return
    end
  end

  add(bucket, "paths", pattern, data, scope, "Hiding inlay hints in")
end

--- Pick an entry to put back.
function M.unignore()
  local data = read_store()
  local root = root_for(vim.api.nvim_get_current_buf())

  ---@type { bucket: user.inlay_hints.Bucket, field: string, text: string, scope: string }[]
  local entries = {}
  local function collect(bucket, scope)
    if not bucket then return end
    for _, field in ipairs { "callees", "paths" } do
      for _, text in ipairs(bucket[field]) do
        table.insert(entries, { bucket = bucket, field = field, text = text, scope = scope })
      end
    end
  end
  collect(root and data.projects[root], "project")
  collect(data.global, "global")

  if #entries == 0 then
    notify "Nothing is ignored here"
    return
  end

  vim.ui.select(entries, {
    prompt = "Show inlay hints again for:",
    format_item = function(entry)
      return ("%-7s %-7s %s"):format(entry.scope, entry.field == "callees" and "callee" or "path", entry.text)
    end,
  }, function(choice)
    if not choice then return end
    choice.bucket[choice.field] = vim.tbl_filter(function(v) return v ~= choice.text end, choice.bucket[choice.field])
    if write_store(data) then
      notify("Showing inlay hints for " .. choice.text .. " again")
      M.refresh()
    end
  end)
end

--- What is being hidden here, and which file says so.
function M.ignored()
  local data = read_store()
  local root = root_for(vim.api.nvim_get_current_buf())

  local lines = { STORE }
  local function section(heading, bucket)
    if not bucket or (#bucket.callees == 0 and #bucket.paths == 0) then return end
    table.insert(lines, heading)
    for _, field in ipairs { "callees", "paths" } do
      if #bucket[field] > 0 then
        table.insert(lines, "    " .. field .. ":")
        -- A sorted copy: the cached lists are handed straight back to
        -- `write_store`, and reordering them here would be a surprise.
        local sorted = vim.deepcopy(bucket[field])
        table.sort(sorted)
        for _, entry in ipairs(sorted) do
          table.insert(lines, "      " .. entry)
        end
      end
    end
  end

  section("  global:", data.global)
  section("  " .. (root or "(no project)") .. ":", root and data.projects[root])
  if #lines == 1 then table.insert(lines, "  (nothing ignored)") end
  notify(table.concat(lines, "\n"))
end

--- Open the store for hand-editing. Writing it is enough to apply it:
--- `read_store` re-reads on a changed mtime, and this hangs a refresh off the
--- write so the change shows without a second key.
function M.edit()
  vim.cmd.edit(vim.fn.fnameescape(STORE))
  if vim.uv.fs_stat(STORE) == nil then
    vim.api.nvim_buf_set_lines(0, 0, -1, false, {
      "{",
      '  "global": {',
      '    "callees": [],',
      '    "paths": []',
      "  },",
      '  "projects": {}',
      "}",
    })
  end
  vim.api.nvim_create_autocmd("BufWritePost", {
    buffer = vim.api.nvim_get_current_buf(),
    desc = "Apply the edited inlay hint ignore list",
    callback = function() M.refresh() end,
  })
end

local installed = false

--- Wrap the handler. Safe to call before or after any server starts -- see the
--- header on `_resolve_handler`.
function M.setup()
  if installed then return end
  installed = true

  local original = vim.lsp.handlers["textDocument/inlayHint"]
  vim.lsp.handlers["textDocument/inlayHint"] = function(err, result, ctx, config)
    if not err and type(result) == "table" and #result > 0 then
      -- A bug in here must cost the filtering, not the feature: on error the
      -- unfiltered response goes through exactly as it did before this file.
      local ok, filtered = pcall(M.filter, result, ctx)
      if ok then result = filtered end
    end
    return original(err, result, ctx, config)
  end
end

return M
