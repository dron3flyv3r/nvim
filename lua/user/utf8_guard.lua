-- Invalid UTF-8 in a buffer is what kills roslyn_ls.
--
-- JSON-RPC payloads must be valid UTF-8, and Neovim sends buffer bytes
-- verbatim: it aligns the *ranges* it computes to codepoint boundaries
-- (`vim/lsp/sync.lua`), but it will faithfully transmit a broken byte that is
-- already in the buffer. Roslyn's `System.Text.Json` then throws
-- `Cannot transcode invalid UTF-8 JSON text to UTF-16 string` from inside its
-- request deserializer, where nothing catches it, and the .NET process exits.
-- From this side that looks like "the LSP crashed"; there is no exit message,
-- because the server never got far enough to send one.
--
-- This fixes the payload and nothing else. The buffer and the file are never
-- modified: `:Utf8Fix` exists but only runs when you ask it to.
--
-- Masking rather than deleting is the whole trick. Dropping the byte would
-- leave the server's copy of that line shorter than the buffer, and a server
-- whose document is out of step is not a cosmetic problem -- it hands back
-- edits computed against text you do not have, which is how comments in this
-- project ended up mojibaked and truncated in the first place. A single
-- invalid byte counts as one byte and one UTF-16 unit to Neovim, exactly like
-- one ASCII character, so swapping in `?` keeps every offset aligned.

local M = {}

--- Byte the server sees in place of an invalid one. Any single-byte ASCII
--- character preserves alignment; this one is recognisable in a log.
local MASK = "?"

local function notify(message, level) vim.notify(message, level or vim.log.levels.WARN, { title = "UTF-8 guard" }) end

--- Shape of a UTF-8 sequence, given its lead byte.
---
--- The second-byte ranges are deliberately narrower than 0x80-0xBF for 0xE0,
--- 0xED, 0xF0 and 0xF4: those are the sequences that would otherwise encode an
--- overlong form, a UTF-16 surrogate half, or a codepoint past U+10FFFF.
--- `System.Text.Json` rejects all three, so accepting them here would report a
--- payload as clean and still lose the server.
---@param b integer
---@return integer? length, integer? second_lo, integer? second_hi
local function lead(b)
  if b < 0x80 then return 1 end
  if b >= 0xc2 and b <= 0xdf then return 2, 0x80, 0xbf end
  if b == 0xe0 then return 3, 0xa0, 0xbf end
  if b >= 0xe1 and b <= 0xec then return 3, 0x80, 0xbf end
  if b == 0xed then return 3, 0x80, 0x9f end
  if b >= 0xee and b <= 0xef then return 3, 0x80, 0xbf end
  if b == 0xf0 then return 4, 0x90, 0xbf end
  if b >= 0xf1 and b <= 0xf3 then return 4, 0x80, 0xbf end
  if b == 0xf4 then return 4, 0x80, 0x8f end
  -- 0x80-0xc1 is a stray continuation byte or an overlong two-byte lead;
  -- 0xf5-0xff never appears in UTF-8 at all.
  return nil
end

--- Byte offsets of every invalid sequence in `s`, 1-based.
---
--- Recovery after a bad byte restarts at the *next* byte rather than skipping
--- the sequence, because the length of something invalid is not known.
---@param s string
---@return integer[]
function M.invalid_offsets(s)
  local found = {}
  local i, n = 1, #s
  while i <= n do
    local len, lo, hi = lead(s:byte(i))
    local bad = false

    if not len then
      bad = true
    elseif len > 1 then
      if i + len - 1 > n then
        bad = true -- truncated at end of line
      else
        local second = s:byte(i + 1)
        if second < lo or second > hi then
          bad = true
        else
          for k = i + 2, i + len - 1 do
            local c = s:byte(k)
            if c < 0x80 or c > 0xbf then
              bad = true
              break
            end
          end
        end
      end
    end

    if bad then
      found[#found + 1] = i
      i = i + 1
    else
      i = i + len
    end
  end
  return found
end

--- `s` with every invalid byte replaced by `MASK`, same length in bytes and in
--- UTF-16 units. This is what goes on the wire.
---@param s string
---@return string masked, integer count
function M.mask(s)
  local offsets = M.invalid_offsets(s)
  if #offsets == 0 then return s, 0 end
  -- Order does not matter here the way it does in `strip`: a mask is the same
  -- width as what it replaces, so no offset moves.
  for _, at in ipairs(offsets) do
    s = s:sub(1, at - 1) .. MASK .. s:sub(at + 1)
  end
  return s, #offsets
end

--- `s` with every invalid byte removed. Only `:Utf8Fix` uses this.
---@param s string
---@return string stripped, integer removed
function M.strip(s)
  local offsets = M.invalid_offsets(s)
  if #offsets == 0 then return s, 0 end
  -- Right to left, so an earlier removal cannot move a later offset.
  for i = #offsets, 1, -1 do
    local at = offsets[i]
    s = s:sub(1, at - 1) .. s:sub(at + 1)
  end
  return s, #offsets
end

---@class user.utf8_guard.Hit
---@field lnum integer 1-based line
---@field col integer 1-based byte column
---@field bytes string Hex of the offending byte

--- Scan `first`..`last` (0-based, end-exclusive; the whole buffer by default).
---@param bufnr integer
---@param first? integer
---@param last? integer
---@return user.utf8_guard.Hit[]
function M.scan(bufnr, first, last)
  if not vim.api.nvim_buf_is_valid(bufnr) then return {} end
  first = first or 0

  local hits = {}
  for offset, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, first, last or -1, false)) do
    for _, at in ipairs(M.invalid_offsets(line)) do
      hits[#hits + 1] = { lnum = first + offset, col = at, bytes = ("%02x"):format(line:byte(at)) }
    end
  end
  return hits
end

---@param hits user.utf8_guard.Hit[]
---@return string
local function describe(hits)
  local parts = {}
  for _, hit in ipairs(hits) do
    parts[#parts + 1] = ("line %d col %d (0x%s)"):format(hit.lnum, hit.col, hit.bytes)
  end
  return table.concat(parts, ", ")
end

--- Delete every invalid byte in `bufnr`. Only ever called from `:Utf8Fix`.
---
--- Deletion rather than masking: `?` is the right thing to show a language
--- server and the wrong thing to leave in a source file, and a lone lead byte
--- has no original to restore anyway -- whatever it used to be is only
--- recoverable from git.
---@param bufnr? integer Defaults to the current buffer.
---@return integer removed
function M.fix(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local seen, removed = {}, 0
  for _, hit in ipairs(M.scan(bufnr)) do
    if not seen[hit.lnum] then
      seen[hit.lnum] = true
      local line = vim.api.nvim_buf_get_lines(bufnr, hit.lnum - 1, hit.lnum, false)[1]
      local stripped, count = M.strip(line)
      if count > 0 then
        vim.api.nvim_buf_set_lines(bufnr, hit.lnum - 1, hit.lnum, false, { stripped })
        removed = removed + count
      end
    end
  end
  return removed
end

--- Report the current buffer and jump to the first bad byte.
function M.check()
  local hits = M.scan(vim.api.nvim_get_current_buf())
  if #hits == 0 then
    vim.notify("Buffer is valid UTF-8", vim.log.levels.INFO, { title = "UTF-8 guard" })
    return
  end
  notify(("Invalid UTF-8 at %s"):format(describe(hits)))
  pcall(vim.api.nvim_win_set_cursor, 0, { hits[1].lnum, hits[1].col - 1 })
end

--- Clients whose `notify` has already been wrapped.
---@type table<integer, true>
local protected = {}

--- Documents already reported, so a permanently broken byte is mentioned once
--- rather than on every keystroke that touches its line.
---@type table<string, true>
local warned = {}

--- Stop invalid UTF-8 from reaching `client` on the wire.
---@param client vim.lsp.Client
function M.protect(client)
  if protected[client.id] then return end
  protected[client.id] = true

  local original = client.notify
  ---@diagnostic disable-next-line: duplicate-set-field
  client.notify = function(self, method, params)
    if method == "textDocument/didChange" and type(params) == "table" then
      local changes = type(params.contentChanges) == "table" and params.contentChanges or {}
      local masked = 0
      for _, change in ipairs(changes) do
        if type(change.text) == "string" then
          local clean, count = M.mask(change.text)
          if count > 0 then
            change.text = clean
            masked = masked + count
          end
        end
      end

      if masked > 0 then
        local uri = type(params.textDocument) == "table" and params.textDocument.uri or "?"
        local key = client.id .. "\0" .. tostring(uri)
        if not warned[key] then
          warned[key] = true
          notify(
            ("Masked %d invalid byte%s sent to %s for %s.\nThe buffer is untouched; :Utf8Check locates it, :Utf8Fix removes it."):format(
              masked,
              masked == 1 and "" or "s",
              client.name,
              vim.fn.fnamemodify(vim.uri_to_fname(tostring(uri)), ":t")
            ),
            vim.log.levels.INFO
          )
        end
      end
    end
    return original(self, method, params)
  end
end

function M.setup()
  vim.api.nvim_create_autocmd("LspAttach", {
    group = vim.api.nvim_create_augroup("user_utf8_guard", { clear = true }),
    desc = "Sanitize didChange payloads before they leave Neovim",
    callback = function(args)
      local client = vim.lsp.get_client_by_id(args.data.client_id)
      if client then M.protect(client) end
    end,
  })
end

return M
