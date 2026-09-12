-- Teamtype paints every peer with `TermCursor` and a grey name label (see
-- `teamtype/cursor.lua`), so two peers look identical and an active selection
-- looks exactly like a resting cursor. `set_cursor` is wrapped here to re-stamp
-- the extmarks it just created: same namespace, same ids, so Teamtype keeps
-- owning their lifetime -- including its own expiry timer and the deletion of a
-- peer's previous marks -- while the look and the registry below are ours.
local M = {}

local palette = {
  "#7dcfff",
  "#bb9af7",
  "#9ece6a",
  "#e0af68",
  "#f7768e",
  "#41a6b5",
}

-- Mirrors `cursor_timeout_ms` in teamtype-nvim: a silent peer's marks disappear
-- there, so the registry has to forget that peer at the same point.
local timeout_ms = 300 * 1000

-- Same name, therefore the same namespace id that teamtype-nvim asked for.
local namespace = vim.api.nvim_create_namespace "Teamtype"

---@class user.teamtype.Peer
---@field id string identifier assigned by the daemon
---@field name string display name of the peer
---@field uri string file the peer is in
---@field bufnr integer buffer for `uri`, possibly still unloaded
---@field line integer 0-indexed line of the peer's first range
---@field column integer 0-indexed start column of the peer's first range
---@field selecting boolean whether the peer is holding a visual selection
---@field lines integer lines the selection covers, 1 for a plain cursor
---@field slot integer palette entry, stable for the session
---@field updated_at integer `vim.uv.now()` of the last update

local original
local wrapper
local slots = {}
---@type table<string, user.teamtype.Peer>
local registry = {}
local subscribers = {}

---@param color integer
---@param other integer
---@param ratio number weight of `color`
---@return integer
local function mix(color, other, ratio)
  local blended = 0
  for _, shift in ipairs { 65536, 256, 1 } do
    local channel = math.floor(color / shift) % 256 * ratio + math.floor(other / shift) % 256 * (1 - ratio)
    blended = blended + math.floor(channel + 0.5) * shift
  end
  return blended
end

---@return integer
local function backdrop()
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  if normal.bg then return normal.bg end
  -- A transparent colorscheme still has to blend against something.
  return vim.o.background == "light" and 0xffffff or 0x000000
end

---@param slot integer
---@param part string
---@return string
local function group(slot, part) return ("TeamtypePeer%d%s"):format(slot, part) end

local function define_highlights()
  local bg = backdrop()
  for slot, color in ipairs(palette) do
    local value = tonumber(color:sub(2), 16)
    -- The caret is the peer's colour as a solid block; the selection is the same
    -- hue mixed far enough into the background that syntax stays readable
    -- underneath it (the extmarks combine rather than replace).
    vim.api.nvim_set_hl(0, group(slot, "Caret"), { bg = value, fg = bg, bold = true })
    vim.api.nvim_set_hl(0, group(slot, "Selection"), { bg = mix(value, bg, 0.22) })
    vim.api.nvim_set_hl(0, group(slot, "Label"), { fg = value, italic = true })
    vim.api.nvim_set_hl(0, group(slot, "Sign"), { fg = value })
  end
end

---@param id string
---@return integer
local function slot_for(id)
  if not slots[id] then
    local taken = {}
    for _, slot in pairs(slots) do
      taken[slot] = true
    end
    local free
    for candidate = 1, #palette do
      if not taken[candidate] then
        free = candidate
        break
      end
    end
    -- More peers than colours is the only case that has to repeat one.
    slots[id] = free or (#vim.tbl_keys(slots) % #palette) + 1
  end
  return slots[id]
end

---@param name string
---@return string
local function initial(name)
  local character = vim.fn.strcharpart(name, 0, 1)
  if character == "" then return "??" end
  -- `sign_text` has to be one or two display cells wide, and a fixed two keeps
  -- the sign column from shifting between peers.
  return vim.fn.strdisplaywidth(character) == 1 and (character .. " ") or character
end

---@param bufnr integer
---@return table<integer, true>
local function extmark_ids(bufnr)
  local seen = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1, {})) do
    seen[mark[1]] = true
  end
  return seen
end

---@param bufnr integer
---@param before table<integer, true> ids that existed before Teamtype ran
---@param peer user.teamtype.Peer
local function restamp(bufnr, before, peer)
  local fresh = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1, { details = true })) do
    if not before[mark[1]] then fresh[#fresh + 1] = mark end
  end
  if #fresh == 0 then return end

  -- Teamtype labels the first range it created; keeping the label and the sign
  -- on the same mark means blockwise selections get one of each, not one per row.
  local labelled = fresh[1]
  for _, mark in ipairs(fresh) do
    if next(mark[4].virt_text or {}) then
      labelled = mark
      break
    end
  end

  for _, mark in ipairs(fresh) do
    local id, row, column, details = mark[1], mark[2], mark[3], mark[4]
    local decorated = mark == labelled
    pcall(vim.api.nvim_buf_set_extmark, bufnr, namespace, row, column, {
      id = id,
      end_row = details.end_row,
      end_col = details.end_col,
      hl_group = group(peer.slot, peer.selecting and "Selection" or "Caret"),
      hl_mode = "combine",
      -- The caret has to win over its own selection where the two overlap.
      priority = peer.selecting and 150 or 300,
      virt_text = decorated and { { " " .. peer.name, group(peer.slot, "Label") } } or nil,
      sign_text = decorated and initial(peer.name) or nil,
      sign_hl_group = decorated and group(peer.slot, "Sign") or nil,
    })
  end
end

---The daemon's fields arrive from JSON, where a null becomes `vim.NIL`. That is
---userdata and therefore truthy, so `name or fallback` is not enough: an unnamed
---peer would carry userdata everywhere a string is expected.
---@param value any
---@param fallback string
---@return string
local function text(value, fallback)
  if type(value) == "string" and value ~= "" then return value end
  if type(value) == "number" then return tostring(value) end
  return fallback
end

---@param uri string
---@param id string
---@param name string?
---@param ranges lsp.Range[]
---@param bufnr integer
---@return user.teamtype.Peer
local function record(uri, id, name, ranges, bufnr)
  local key = text(id, "peer")
  local first = ranges[1]
  local lines = 1
  local selecting = false
  for _, range in ipairs(ranges) do
    if range.start.line ~= range["end"].line or range.start.character ~= range["end"].character then
      selecting = true
    end
    lines = math.max(lines, range["end"].line - range.start.line + 1)
  end

  local peer = {
    id = key,
    name = text(name, "unnamed peer"),
    uri = uri,
    bufnr = bufnr,
    line = first and first.start.line or 0,
    column = first and first.start.character or 0,
    selecting = selecting,
    lines = lines,
    slot = slot_for(key),
    updated_at = vim.uv.now(),
  }
  registry[key] = peer
  return peer
end

---Peers heard from recently, ordered by name so the panel does not reshuffle.
---@return user.teamtype.Peer[]
function M.list()
  local now = vim.uv.now()
  local peers = {}
  for id, peer in pairs(registry) do
    if now - peer.updated_at > timeout_ms then
      registry[id] = nil
    else
      peers[#peers + 1] = peer
    end
  end
  -- The id breaks ties, or two peers sharing a name would swap places.
  table.sort(peers, function(a, b)
    if a.name ~= b.name then return a.name < b.name end
    return a.id < b.id
  end)
  return peers
end

---@param callback fun(peer: user.teamtype.Peer?)
function M.subscribe(callback) subscribers[#subscribers + 1] = callback end

---@return boolean installed
function M.setup()
  local ok, cursor = pcall(require, "teamtype.cursor")
  if not ok then return false end
  -- Comparing against our own wrapper keeps this idempotent without assuming
  -- the module is the same table it was the last time around.
  if wrapper and cursor.set_cursor == wrapper then return true end

  original = cursor.set_cursor
  wrapper = function(uri, id, name, ranges)
    local bufnr = vim.uri_to_bufnr(uri)
    local before = vim.api.nvim_buf_is_loaded(bufnr) and extmark_ids(bufnr) or nil

    original(uri, id, name, ranges)

    -- Never let the extra bookkeeping break synchronisation itself.
    local recorded, peer = pcall(record, uri, id, name, ranges, bufnr)
    if not recorded then return end
    if before then pcall(restamp, bufnr, before, peer) end
    for _, callback in ipairs(subscribers) do
      pcall(callback, peer)
    end
  end
  cursor.set_cursor = wrapper

  define_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("user_teamtype_peers", { clear = true }),
    pattern = "*",
    callback = define_highlights,
  })
  return true
end

return M
