local M = {}

---@class plugins.collaboration.Peer
---@field name string
---@field uri string
---@field range lsp.Range

---@type table<string, plugins.collaboration.Peer>
local peers = {}
---@type string?
local following
---@type integer?
local win

local function notify(message, level) vim.notify(message, level or vim.log.levels.INFO, { title = "Teamtype" }) end

---@param peer plugins.collaboration.Peer
---@return string
local function title(peer)
  return (" %s · %s "):format(peer.name, vim.fn.fnamemodify(vim.uri_to_fname(peer.uri), ":~:."))
end

---@return vim.api.keyset.win_config
local function geometry()
  return {
    relative = "editor",
    anchor = "NE",
    row = 1,
    col = vim.o.columns,
    width = math.max(40, math.floor(vim.o.columns * 0.45)),
    height = math.max(8, math.floor(vim.o.lines * 0.4)),
  }
end

---@param bufnr integer
---@param peer plugins.collaboration.Peer
local function open(bufnr, peer)
  local config = geometry()
  config.border = "rounded"
  config.title = title(peer)
  config.title_pos = "center"
  win = vim.api.nvim_open_win(bufnr, false, config)
  for option, value in pairs { diff = false, scrollbind = false, cursorbind = false, cursorline = true } do
    vim.wo[win][option] = value
  end
  vim.api.nvim_create_autocmd("WinClosed", {
    group = vim.api.nvim_create_augroup("plugins_collaboration_follow", { clear = true }),
    pattern = tostring(win),
    once = true,
    callback = function()
      win = nil
      following = nil
    end,
  })
end

---@param peer plugins.collaboration.Peer
local function show(peer)
  local bufnr = vim.uri_to_bufnr(peer.uri)
  if not vim.api.nvim_buf_is_loaded(bufnr) then vim.fn.bufload(bufnr) end
  if win and vim.api.nvim_win_is_valid(win) then
    if vim.api.nvim_win_get_buf(win) ~= bufnr then vim.api.nvim_win_set_buf(win, bufnr) end
    vim.api.nvim_win_set_config(win, { title = title(peer), title_pos = "center" })
  else
    open(bufnr, peer)
  end
  local line = math.min(peer.range.start.line + 1, vim.api.nvim_buf_line_count(bufnr))
  local text = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or ""
  vim.api.nvim_win_set_cursor(win, { line, vim.str_byteindex(text, "utf-32", peer.range.start.character, false) })
end

function M.track()
  local cursor = require "teamtype.cursor"
  local set_cursor = cursor.set_cursor
  cursor.set_cursor = function(uri, user_id, name, ranges)
    set_cursor(uri, user_id, name, ranges)
    if not (ranges and ranges[1]) then return end
    peers[user_id] = { name = name or "Someone", uri = uri, range = ranges[1] }
    if following == user_id then
      local ok, err = pcall(show, peers[user_id])
      if not ok then notify(err, vim.log.levels.WARN) end
    end
  end
end

---@return string?
function M.following() return following and peers[following].name end

function M.stop()
  following = nil
  if win and vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  win = nil
end

---@param id string
local function start(id)
  show(peers[id])
  following = id
end

function M.toggle()
  if following then return M.stop() end
  local ids = vim.tbl_keys(peers)
  if #ids == 0 then return notify "No teammate has moved their cursor since this editor connected" end
  if #ids == 1 then return start(ids[1]) end
  table.sort(ids, function(a, b) return peers[a].name < peers[b].name end)
  vim.ui.select(ids, {
    prompt = "Follow",
    format_item = function(id)
      local peer = peers[id]
      local file = vim.fn.fnamemodify(vim.uri_to_fname(peer.uri), ":~:.")
      return ("%s  %s:%d"):format(peer.name, file, peer.range.start.line + 1)
    end,
  }, function(id)
    if id then start(id) end
  end)
end

return M
