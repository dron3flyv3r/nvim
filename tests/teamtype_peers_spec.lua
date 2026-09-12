-- Teamtype's own `set_cursor` is stubbed here with a reduced copy of what it
-- does to extmarks, so the re-stamping can be checked without a live daemon.
local namespace = vim.api.nvim_create_namespace "Teamtype"

local function same(actual, expected, label)
  assert(
    vim.deep_equal(actual, expected),
    ("%s: expected %s, got %s"):format(label, vim.inspect(expected), vim.inspect(actual))
  )
end

local owned = {}
package.loaded["teamtype.cursor"] = {
  set_cursor = function(uri, user_id, name, ranges)
    local bufnr = vim.uri_to_bufnr(uri)
    for _, id in ipairs(owned[user_id] or {}) do
      vim.api.nvim_buf_del_extmark(bufnr, namespace, id)
    end
    owned[user_id] = {}

    for index, range in ipairs(ranges) do
      local start_column = range.start.character
      local end_column = range["end"].character
      -- Teamtype widens an empty range so a resting cursor stays visible.
      if range.start.line == range["end"].line and start_column == end_column then end_column = end_column + 1 end
      -- Teamtype swallows extmark failures, which is how an unnamed peer still
      -- reaches the registry with nothing drawn for it.
      local ok, id = pcall(vim.api.nvim_buf_set_extmark, bufnr, namespace, range.start.line, start_column, {
        hl_mode = "combine",
        hl_group = "TermCursor",
        end_row = range["end"].line,
        end_col = end_column,
        virt_text = index == 1 and name and { { name, "TeamtypeUsername" } } or {},
      })
      if ok then owned[user_id][index] = id end
    end
  end,
}

local peers = require "user.teamtype.peers"
assert(peers.setup(), "the cursor hook must install")
local cursor = package.loaded["teamtype.cursor"]

local path = vim.fn.tempname() .. ".lua"
vim.fn.writefile({ "local one = 1", "local two = 2", "local three = 3" }, path)
local uri = vim.uri_from_fname(path)
local bufnr = vim.fn.bufadd(path)
vim.fn.bufload(bufnr)

---@return vim.api.keyset.extmark_details
local function only_mark()
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1, { details = true })
  assert(#marks == 1, ("expected one extmark, got %d"):format(#marks))
  return marks[1][4]
end

local function position(line, character) return { line = line, character = character } end

-- A resting cursor: solid caret, name label, and a sign carrying the initial.
cursor.set_cursor(uri, "peer-a", "alice", { { start = position(1, 4), ["end"] = position(1, 4) } })
local caret = only_mark()
same(caret.hl_group, "TeamtypePeer1Caret", "caret highlight")
same(caret.virt_text, { { " alice", "TeamtypePeer1Label" } }, "caret label")
same(caret.sign_text, "a ", "caret sign")
same(caret.sign_hl_group, "TeamtypePeer1Sign", "caret sign highlight")
same(caret.hl_mode, "combine", "caret blends with syntax")

local alice = peers.list()[1]
same({ alice.name, alice.line, alice.selecting, alice.lines }, { "alice", 1, false, 1 }, "resting cursor registry")

-- A selection over two lines: tinted range instead of a caret.
cursor.set_cursor(uri, "peer-a", "alice", { { start = position(0, 6), ["end"] = position(1, 9) } })
local selection = only_mark()
same(selection.hl_group, "TeamtypePeer1Selection", "selection highlight")
assert(selection.hl_group ~= caret.hl_group, "a selection must not look like a resting cursor")
alice = peers.list()[1]
same({ alice.line, alice.selecting, alice.lines }, { 0, true, 2 }, "selection registry")

-- Blockwise selections arrive as one range per row; only one carries the label.
cursor.set_cursor(uri, "peer-a", "alice", {
  { start = position(0, 2), ["end"] = position(0, 5) },
  { start = position(1, 2), ["end"] = position(1, 5) },
})
local labels, signs = 0, 0
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1, { details = true })) do
  same(mark[4].hl_group, "TeamtypePeer1Selection", "blockwise highlight")
  if mark[4].virt_text then labels = labels + 1 end
  if mark[4].sign_text then signs = signs + 1 end
end
same({ labels, signs }, { 1, 1 }, "one label and one sign per blockwise selection")

-- A second peer has to be told apart from the first by colour alone.
cursor.set_cursor(uri, "peer-b", "bob", { { start = position(2, 0), ["end"] = position(2, 0) } })
local slots = {}
for _, peer in ipairs(peers.list()) do
  slots[peer.name] = peer.slot
end
same(#peers.list(), 2, "both peers are tracked")
assert(slots.alice ~= slots.bob, "peers must get different palette slots")

-- Palette slots are stable across updates, or peers would change colour as they move.
cursor.set_cursor(uri, "peer-b", "bob", { { start = position(0, 0), ["end"] = position(0, 3) } })
for _, peer in ipairs(peers.list()) do
  same(peer.slot, slots[peer.name], "stable palette slot for " .. peer.name)
end

-- An unnamed peer arrives as a JSON null, which is `vim.NIL`: truthy userdata
-- that used to reach the panel and break sorting.
cursor.set_cursor(uri, "peer-c", vim.NIL, { { start = position(0, 0), ["end"] = position(0, 0) } })
same(#peers.list(), 3, "the unnamed peer is tracked")
for _, peer in ipairs(peers.list()) do
  same(type(peer.name), "string", "every peer name has to be a string")
  same(type(peer.id), "string", "every peer id has to be a string")
end

-- Borrowing a window has to be reversible: taking a split over must hand it back
-- to the buffer and cursor it was showing.
local panel = require "user.teamtype.panel"
vim.cmd "vsplit"
local split = vim.api.nvim_get_current_win()
local restore = { buf = vim.api.nvim_win_get_buf(split), cursor = vim.api.nvim_win_get_cursor(split) }
assert(restore.buf ~= bufnr, "the split has to start on a different buffer for this to prove anything")

panel.mirror { id = "peer-a", here = true }
same(#vim.api.nvim_tabpage_list_wins(0), 2, "following in this window must not open another one")
same(vim.api.nvim_win_get_buf(split), bufnr, "the split took on the peer's buffer")

cursor.set_cursor(uri, "peer-a", "alice", { { start = position(2, 0), ["end"] = position(2, 0) } })
same(vim.api.nvim_win_get_cursor(split)[1], 3, "the split follows the peer")

panel.mirror_stop(split)
same(vim.api.nvim_win_get_buf(split), restore.buf, "the split was handed back")
same(vim.api.nvim_win_get_cursor(split), restore.cursor, "the split's cursor was restored")
vim.api.nvim_win_close(split, true)

vim.uv.fs_unlink(path)
