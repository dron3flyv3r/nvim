-- A blink.cmp source: type `Application::` in a .cpp and get the *whole*
-- out-of-line definition -- return type, parameters, const, the lot -- as a
-- completion item.
--
-- WHY THIS EXISTS: because clangd does not do it, which is genuinely
-- surprising. Asking clangd to complete `Application::ini` at namespace scope
-- in a source file returns exactly one item:
--
--     label = " init", detail = "void", labelDetails = { detail = "()" },
--     insertText = "init", insertTextFormat = 1 (PlainText)
--
-- It completes the *name*. Accepting it leaves you with `Application::init`
-- and a syntax error, and you still type the return type and the parameter
-- list by hand -- which is the entire job. (`Application::` with nothing after
-- it is worse: clangd cannot parse the incomplete construct, gives up on the
-- scope, and returns 100 items of global namespace -- `FILE`, `size_t`,
-- `alloca`.) There is no clangd setting that changes this; the information is
-- there in `detail` and `labelDetails`, but nothing assembles it.
--
-- So this assembles it. It does NOT re-implement the assembling -- getting
-- `const`, reference qualifiers, template parameters and stripped default
-- arguments right is exactly the part that is easy to get wrong, and
-- nt-cpp-tools already does it correctly for `<Leader>lcp`. This drives that
-- same generator against the paired header and reshapes its output into
-- completion items, so the text you accept here and the text `<Leader>lcp`
-- writes are produced by the same code.
--
-- HOW IT RELATES TO `<Leader>lcp`, which does the same job from the other end:
--
--     in the header, know what you want   -> `<Leader>lcp`, all of them at once
--     in the .cpp, typing already         -> this, one at a time, in flow
--
-- The second is the one that answers "I might update the inputs later": when a
-- signature changes, delete the stale definition and re-type `Application::`
-- -- the item you get back is generated from the header as it is now.

local source = {}

--- Header extensions to look for beside the source file, in order.
local HEADER_EXTS = { ".h", ".hpp", ".hh", ".hxx" }

--- Source files this makes sense in. Not headers: an out-of-line definition
--- inside the header that declares it is legal but not what anybody means.
local SOURCE_EXTS = { [".cpp"] = true, [".cc"] = true, [".cxx"] = true, [".c"] = true }

--- Generated definitions, keyed by header path.
---
--- `get_completions` runs on every keystroke after `::`, and each run otherwise
--- re-parses the header and walks its tree. The header's `changedtick` is the
--- invalidation: edit the class, and the next completion regenerates.
---@type table<string, { tick: integer, defs: table[] }>
local cache = {}

function source.new() return setmetatable({}, { __index = source }) end

--- `::` is the trigger. Blink also re-queries on each subsequent character, so
--- `Application::i`, `::in`, `::ini` all come back through here without `:`
--- being retyped.
function source:get_trigger_characters() return { ":" } end

--- The paired header for a source file, or nil.
---
--- A same-directory extension swap, which is what both projects here need
--- (`application.cpp` -> `application.h`). It deliberately does not go looking
--- in `include/`: clangd's `switchSourceHeader` would find those, but it is an
--- async LSP round trip and this runs inside a completion callback that has to
--- answer now. `<Leader>lcp` from the header side covers that layout.
---@param path string
---@return string?
local function paired_header(path)
  local stem = path:gsub("%.[^./]+$", "")
  for _, ext in ipairs(HEADER_EXTS) do
    local candidate = stem .. ext
    if vim.uv.fs_stat(candidate) then return candidate end
  end
  return nil
end

--- The header's text, and a token that changes when the text does.
---
--- Prefers an already-open buffer over the file on disk, because the pair is
--- usually open together and the unsaved edit you just made to the class is
--- exactly the one you want completed against.
---@param header string
---@return string[]? lines, string? version
local function header_lines(header)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.api.nvim_buf_get_name(bufnr) == header then
      return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
        "buf:" .. vim.api.nvim_buf_get_changedtick(bufnr)
    end
  end

  local ok, lines = pcall(vim.fn.readfile, header)
  if not ok or type(lines) ~= "table" then return nil end
  local stat = vim.uv.fs_stat(header)
  return lines, ("disk:%d:%d"):format(stat and stat.mtime.sec or 0, stat and stat.size or 0)
end

--- The scratch buffer the generator is run inside, created once and reused.
---
--- NOT the header's own buffer, and emphatically not `bufadd` + `bufload` on
--- it: loading a file Neovim has not opened yet runs the whole file-opening
--- path, and if that file has a swap file -- because it is open in another
--- Neovim, which for a header you are working on is the normal case -- it stops
--- and asks. A modal "found a swap file" prompt in the middle of a completion
--- request is about the worst thing this could do; it hung a test for ninety
--- seconds before it ever ran a line of the generator.
---
--- A scratch buffer has no file behind it, so no swap file, no autocmds, no
--- LSP attach, and nothing to prompt about.
---@type integer?
local scratch

---@return integer
local function scratch_buffer()
  if not scratch or not vim.api.nvim_buf_is_valid(scratch) then
    scratch = vim.api.nvim_create_buf(false, true)
    -- The generator passes the filetype straight to `vim.treesitter.get_parser`,
    -- so this is what makes it parse C++ rather than nothing.
    vim.bo[scratch].filetype = "cpp"
    vim.bo[scratch].swapfile = false
  end
  return scratch
end

--- Every out-of-line definition the header's classes imply.
---
--- `imp_func(first, last, cb)` is nt-cpp-tools' generator with its output
--- handler replaced by `cb`, so nothing is written anywhere -- we just take the
--- string. It reads the *current* buffer, hence `nvim_buf_call`.
---@param header string
---@return table[] definitions with `class`, `name` and `signature`
local function definitions(header)
  local lines, version = header_lines(header)
  if not lines then return {} end

  local entry = cache[header]
  if entry and entry.tick == version then return entry.defs end

  local ok, internal = pcall(require, "nt-cpp-tools.internal")
  if not ok then return {} end

  local bufnr = scratch_buffer()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

  local output
  vim.api.nvim_buf_call(bufnr, function()
    pcall(internal.imp_func, 1, #lines, function(generated) output = generated end)
  end)

  local defs = {}
  if output then
    -- The generator emits `<signature>\n{\n}\n` per function, where the
    -- signature may itself span lines when a template statement precedes it.
    for signature in (output .. "\n"):gmatch "(.-)\n{\n}\n" do
      local class, name = signature:match "([%w_]+)::(~?[%w_]+)%s*%("
      if class and name then
        table.insert(defs, { class = class, name = name, signature = signature })
      end
    end
  end

  cache[header] = { tick = version, defs = defs }
  return defs
end

--- Escape the two characters an LSP snippet treats as syntax.
---
--- Default arguments are stripped from out-of-line definitions, so a `$` in a
--- generated signature is close to impossible -- but "close to impossible"
--- inserted as a snippet placeholder silently eats text, so it is cheaper to
--- escape than to reason about.
---@param text string
---@return string
local function escape_snippet(text) return (text:gsub("[\\$}]", "\\%0")) end

function source:enabled()
  local name = vim.api.nvim_buf_get_name(0)
  return SOURCE_EXTS[(name:match "%.[^./]+$" or "")] == true
end

---@param ctx blink.cmp.Context
---@param callback function
function source:get_completions(ctx, callback)
  local empty = { is_incomplete_backward = false, is_incomplete_forward = false, items = {} }

  -- `Class::partial` immediately before the cursor. The `~` allows a
  -- destructor, which is the one member whose name is not an identifier.
  local before = ctx.line:sub(1, ctx.cursor[2])
  local class, partial = before:match "([%w_]+)::(~?[%w_]*)$"
  if not class then return callback(empty) end

  local header = paired_header(vim.api.nvim_buf_get_name(ctx.bufnr))
  if not header then return callback(empty) end

  -- What this file already defines, so a member that is done does not keep
  -- being offered. A plain substring search rather than a parse: the text
  -- being matched is `Class::name(`, which does not occur by accident, and
  -- this runs on every keystroke.
  local body = table.concat(vim.api.nvim_buf_get_lines(ctx.bufnr, 0, -1, false), "\n")

  local start_col = #before - #(class .. "::" .. partial)
  local line = ctx.cursor[1] - 1

  local items = {}
  for _, def in ipairs(definitions(header)) do
    if def.class == class and not body:find(def.class .. "::" .. def.name .. "(", 1, true) then
      -- The generated text already contains `Class::name`, so the edit has to
      -- replace what was typed rather than append to it -- otherwise accepting
      -- gives `Application::Application::init()`.
      table.insert(items, {
        label = def.signature:gsub("%s+", " "),
        filterText = def.name,
        -- `Method`, so it takes the same icon and highlight as clangd's own
        -- member completions rather than looking like a snippet.
        kind = vim.lsp.protocol.CompletionItemKind.Method,
        insertTextFormat = vim.lsp.protocol.InsertTextFormat.Snippet,
        textEdit = {
          range = {
            start = { line = line, character = start_col },
            ["end"] = { line = line, character = ctx.cursor[2] },
          },
          -- `$0` puts the cursor on the empty line inside the braces, which is
          -- where you were going to type next anyway.
          newText = escape_snippet(def.signature) .. " {\n\t$0\n}",
        },
        documentation = { kind = "markdown", value = "```cpp\n" .. def.signature .. "\n{\n}\n```" },
      })
    end
  end

  callback {
    is_incomplete_backward = false,
    -- The item set depends only on the header and what this file already
    -- defines, so blink can filter the rest of the word itself rather than
    -- asking again on every character.
    is_incomplete_forward = false,
    items = items,
  }
end

return source
