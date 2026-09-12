-- Two persistent views over the peer registry: a sidebar listing where everyone
-- is, and a mirror window pinned to one peer. Both are read-only observers --
-- unlike `:TeamtypeFollow`, which moves your own cursor and stops at the first
-- key you press.
local M = {}

local peers = require "user.teamtype.peers"

local namespace = vim.api.nvim_create_namespace "user_teamtype_panel"
local width = 34
local mirror_height = 12

local panel = { win = nil, buf = nil, lines = {}, timer = nil, closing = false }

---Windows currently pinned to a peer, keyed by window id. A borrowed split also
---remembers what it was showing so it can be handed back.
---@type table<integer, { id: string, uri: string?, float: boolean, buf: integer?, cursor: integer[]?, winbar: string? }>
local mirrors = {}

local function notify(message, level) vim.notify(message, level or vim.log.levels.INFO, { title = "Teamtype" }) end

---@param peer user.teamtype.Peer
---@return string
local function location(peer)
  local path = vim.fn.fnamemodify(vim.uri_to_fname(peer.uri), ":.")
  -- Peers can be in files outside the project, where `:.` leaves the path absolute.
  if path:sub(1, 1) == "/" then path = vim.fn.fnamemodify(path, ":~") end
  return ("%s:%d"):format(path, peer.line + 1)
end

---Keep the tail of an over-long path: the file name matters more than the root.
---@param text string
---@param limit integer
---@return string
local function shorten(text, limit)
  if vim.fn.strdisplaywidth(text) <= limit then return text end
  return "…" .. vim.fn.strcharpart(text, vim.fn.strchars(text) - limit + 1)
end

---@param slot integer
---@param part string
---@return string
local function group(slot, part) return ("TeamtypePeer%d%s"):format(slot, part) end

local function panel_is_open() return panel.win and vim.api.nvim_win_is_valid(panel.win) end

local function render()
  if not panel_is_open() then return end

  local list = peers.list()
  local lines, marks = {}, {}
  panel.lines = {}

  if #list == 0 then lines[#lines + 1] = "No peers connected." end
  for _, peer in ipairs(list) do
    if #lines > 0 then lines[#lines + 1] = "" end

    lines[#lines + 1] = "▌ " .. peer.name
    panel.lines[#lines] = peer
    marks[#marks + 1] = { #lines - 1, group(peer.slot, "Label") }

    local detail = location(peer)
    if peer.selecting then
      detail = detail .. (peer.lines > 1 and (" · %d lines selected"):format(peer.lines) or " · selecting")
    end
    lines[#lines + 1] = "  " .. shorten(detail, width - 3)
    panel.lines[#lines] = peer
  end

  vim.bo[panel.buf].modifiable = true
  vim.api.nvim_buf_set_lines(panel.buf, 0, -1, false, lines)
  vim.bo[panel.buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(panel.buf, namespace, 0, -1)
  for _, mark in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(panel.buf, namespace, mark[1], 0, { end_row = mark[1] + 1, hl_group = mark[2] })
  end
end

---@return user.teamtype.Peer?
local function peer_under_cursor()
  local peer = panel.lines[vim.fn.line "."]
  if not peer then notify("No peer on this line", vim.log.levels.WARN) end
  return peer
end

---@param peer user.teamtype.Peer
local function jump_to(peer)
  -- Never open the peer's file inside the sidebar itself.
  local target
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if win ~= panel.win and vim.api.nvim_win_get_config(win).relative == "" then
      target = win
      break
    end
  end
  if target then
    vim.api.nvim_set_current_win(target)
  else
    vim.cmd "wincmd p"
  end
  vim.cmd.edit(vim.fn.fnameescape(vim.uri_to_fname(peer.uri)))
  pcall(vim.api.nvim_win_set_cursor, 0, { peer.line + 1, peer.column })
  vim.cmd "normal! zz"
end

local function close_panel()
  if panel.closing then return end
  panel.closing = true

  if panel.timer then
    panel.timer:stop()
    panel.timer:close()
    panel.timer = nil
  end
  if panel_is_open() then pcall(vim.api.nvim_win_close, panel.win, true) end
  panel.win, panel.buf, panel.lines = nil, nil, {}
  panel.closing = false
end

local function open_panel()
  panel.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[panel.buf].bufhidden = "wipe"
  vim.bo[panel.buf].filetype = "teamtype-peers"
  vim.bo[panel.buf].modifiable = false

  panel.win = vim.api.nvim_open_win(panel.buf, false, {
    split = "right",
    win = -1, -- full-height split at the far right, not a split of the current window
    width = width,
  })

  local options = vim.wo[panel.win]
  options.number = false
  options.relativenumber = false
  options.signcolumn = "no"
  options.wrap = false
  options.cursorline = true
  options.winfixwidth = true
  options.list = false
  options.statuscolumn = ""
  options.winbar = " 󰙯 Peers"

  vim.keymap.set("n", "<CR>", function()
    local peer = peer_under_cursor()
    if peer then jump_to(peer) end
  end, { buffer = panel.buf, nowait = true, desc = "Jump to this peer" })
  vim.keymap.set("n", "m", function()
    local peer = peer_under_cursor()
    if peer then M.mirror { id = peer.id } end
  end, { buffer = panel.buf, nowait = true, desc = "Mirror this peer in a float" })
  vim.keymap.set("n", "q", close_panel, { buffer = panel.buf, nowait = true, desc = "Close the peer panel" })

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(panel.win),
    once = true,
    callback = function() close_panel() end,
  })

  -- Peer updates drive the rendering, but a peer that simply goes quiet never
  -- sends one, so age the list out on a timer as well.
  panel.timer = vim.uv.new_timer()
  panel.timer:start(10000, 10000, vim.schedule_wrap(render))

  render()
end

function M.toggle()
  if panel_is_open() then
    close_panel()
  else
    open_panel()
  end
end

---@param peer user.teamtype.Peer
local function mirror_title(peer)
  return (" 󰆃 %s · %s "):format(peer.name, vim.fs.basename(vim.uri_to_fname(peer.uri)))
end

---@param win integer
---@param peer user.teamtype.Peer
local function follow(win, peer)
  local state = mirrors[win]
  if not state or not vim.api.nvim_win_is_valid(win) then return end

  if not vim.api.nvim_buf_is_loaded(peer.bufnr) and not pcall(vim.fn.bufload, peer.bufnr) then return end
  if vim.api.nvim_win_get_buf(win) ~= peer.bufnr then pcall(vim.api.nvim_win_set_buf, win, peer.bufnr) end

  if state.uri ~= peer.uri then
    state.uri = peer.uri
    if state.float then
      -- `nvim_win_set_config` wants a whole float config, so retitle a copy of
      -- the current one instead of building a fresh layout.
      local config = vim.api.nvim_win_get_config(win)
      config.title = mirror_title(peer)
      config.title_pos = "center"
      pcall(vim.api.nvim_win_set_config, win, config)
    end
  end
  -- A reused split has no border to write the peer's name into.
  if not state.float then
    vim.api.nvim_set_option_value("winbar", mirror_title(peer), { scope = "local", win = win })
  end

  local last = vim.api.nvim_buf_line_count(peer.bufnr)
  pcall(vim.api.nvim_win_set_cursor, win, { math.min(peer.line + 1, last), 0 })
  -- A float mirror is never focused, so centring has to happen inside the window.
  pcall(vim.api.nvim_win_call, win, function() vim.cmd "normal! zz" end)
end

---@param win integer
local function release(win)
  local state = mirrors[win]
  if not state then return end
  mirrors[win] = nil

  if not vim.api.nvim_win_is_valid(win) then return end
  if state.float then
    pcall(vim.api.nvim_win_close, win, true)
    return
  end
  -- A window we borrowed goes back to whatever it was showing. An empty local
  -- `winbar` is what makes a window fall back to the global one again.
  vim.api.nvim_set_option_value("winbar", state.winbar or "", { scope = "local", win = win })
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    pcall(vim.api.nvim_win_set_buf, win, state.buf)
    pcall(vim.api.nvim_win_set_cursor, win, state.cursor)
  end
end

---Stop mirroring in one window, or in every window when called without one.
---@param win integer? window to release, `0` for the current one
function M.mirror_stop(win)
  if win == 0 then win = vim.api.nvim_get_current_win() end
  if win then
    if not mirrors[win] then
      notify("This window is not mirroring a peer", vim.log.levels.WARN)
      return
    end
    release(win)
    return
  end
  for _, mirrored in ipairs(vim.tbl_keys(mirrors)) do
    release(mirrored)
  end
end

---@param peer user.teamtype.Peer
---@return integer? win
local function open_float(peer)
  local columns = math.min(90, vim.o.columns - 4)
  local win = vim.api.nvim_open_win(peer.bufnr, false, {
    relative = "editor",
    width = columns,
    height = math.min(mirror_height, vim.o.lines - 6),
    row = math.max(1, vim.o.lines - mirror_height - 5),
    col = math.max(0, vim.o.columns - columns - 2),
    border = "rounded",
    title = mirror_title(peer),
    title_pos = "center",
    -- Keeping it out of window navigation is what makes it a mirror rather than
    -- a window you fall into with `<C-w>w`.
    focusable = false,
    style = "minimal",
  })
  vim.wo[win].number = true
  vim.wo[win].signcolumn = "yes"
  vim.wo[win].wrap = false
  return win
end

---@param peer user.teamtype.Peer
---@param here boolean reuse the current window instead of opening a float
local function attach(peer, here)
  if not vim.api.nvim_buf_is_loaded(peer.bufnr) and not pcall(vim.fn.bufload, peer.bufnr) then
    notify("Cannot open " .. vim.uri_to_fname(peer.uri), vim.log.levels.WARN)
    return
  end

  local win
  if here then
    win = vim.api.nvim_get_current_win()
    if win == panel.win then
      notify("Move into an editing window first", vim.log.levels.WARN)
      return
    end
    if not mirrors[win] then
      -- Remember what the window was showing so releasing it puts you back.
      mirrors[win] = {
        float = false,
        buf = vim.api.nvim_win_get_buf(win),
        cursor = vim.api.nvim_win_get_cursor(win),
        winbar = vim.api.nvim_get_option_value("winbar", { scope = "local", win = win }),
      }
    end
  else
    for mirrored, state in pairs(mirrors) do
      -- One float is enough; retarget it rather than stacking another on top.
      if state.float and vim.api.nvim_win_is_valid(mirrored) then win = mirrored end
    end
    win = win or open_float(peer)
    mirrors[win] = mirrors[win] or { float = true }
  end
  if not win then return end

  mirrors[win].id = peer.id
  mirrors[win].uri = nil
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function() mirrors[win] = nil end,
  })

  follow(win, peer)
  notify(("Mirroring %s%s"):format(peer.name, here and " in this window" or ""))
end

---@class user.teamtype.MirrorOpts
---@field id string? peer to mirror; prompts when omitted and more than one is connected
---@field here boolean? take over the current window instead of opening a float

---@param opts user.teamtype.MirrorOpts?
function M.mirror(opts)
  opts = opts or {}
  local list = peers.list()
  if #list == 0 then
    notify("No peers connected", vim.log.levels.WARN)
    return
  end

  if opts.id then
    for _, peer in ipairs(list) do
      if peer.id == opts.id then return attach(peer, opts.here or false) end
    end
    notify("That peer is no longer connected", vim.log.levels.WARN)
    return
  end

  if #list == 1 then return attach(list[1], opts.here or false) end
  vim.ui.select(list, {
    prompt = opts.here and "Follow which peer in this window?" or "Mirror which peer?",
    format_item = function(peer) return ("%s — %s"):format(peer.name, location(peer)) end,
  }, function(peer)
    if peer then attach(peer, opts.here or false) end
  end)
end

function M.setup()
  peers.subscribe(function(peer)
    if peer then
      for win, state in pairs(mirrors) do
        if state.id == peer.id then follow(win, peer) end
      end
    end
    render()
  end)

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("user_teamtype_panel", { clear = true }),
    callback = function()
      M.mirror_stop()
      close_panel()
    end,
  })
end

return M
