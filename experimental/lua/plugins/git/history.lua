local M = {}

local api = vim.api

local STEP = 10

---@class git.history.State
---@field context integer
---@field full boolean

---@type table<table, git.history.State>
local states = setmetatable({}, { __mode = "k" })

---@param message string
local function say(message) vim.notify(message, vim.log.levels.INFO, { title = "Line history" }) end

---@return table?
local function current_view()
  local ok, lib = pcall(require, "diffview.lib")
  if not ok then return nil end
  local found, view = pcall(lib.get_current_view)
  return found and view or nil
end

-- With `++base` the hunks describe a revision that is not on screen, which is
-- also why Diffview skips its own patch folds there.
---@param view table?
---@return table? diff
local function traced_diff(view)
  local panel = view and view.panel
  if not (panel and panel.get_log_options and panel.cur_item and view.cur_entry) then return nil end
  local opts = panel:get_log_options()
  if not (opts and opts.L and next(opts.L)) or opts.base then return nil end
  local log_entry = panel.cur_item[1]
  return log_entry and log_entry.get_diff and log_entry:get_diff(view.cur_entry.path) or nil
end

---@param view table
---@return git.history.State
local function state_of(view)
  states[view] = states[view] or { context = 0, full = false }
  return states[view]
end

-- A side with nothing in the range reports the line it sits after, so that line
-- is the anchor rather than an empty span.
---@param row integer
---@param size integer
---@return integer first, integer last
local function span(row, size)
  if size > 0 then return row, row + size - 1 end
  local anchor = math.max(row, 1)
  return anchor, anchor
end

---@param hunks table[]
---@param side "old"|"new"
---@param context integer
---@param count integer
---@return integer[][]
local function folds_outside(hunks, side, context, count)
  local ranges = {}
  for _, hunk in ipairs(hunks) do
    local first, last = span(hunk[side .. "_row"], hunk[side .. "_size"])
    ranges[#ranges + 1] = { math.max(1, first - context), math.min(count, last + context) }
  end
  table.sort(ranges, function(x, y) return x[1] < y[1] end)

  local folds, free = {}, 1
  for _, range in ipairs(ranges) do
    if range[1] > free then folds[#folds + 1] = { free, range[1] - 1 } end
    free = math.max(free, range[2] + 1)
  end
  if free <= count then folds[#folds + 1] = { free, count } end
  return folds
end

---@param window table? a Diffview layout window
---@return boolean
local function showing_its_file(window)
  local file = window and window.file
  if not (file and file.bufnr and not file.nulled) then return false end
  return api.nvim_win_is_valid(window.id) and api.nvim_win_get_buf(window.id) == file.bufnr
end

---@param winid integer
---@param folds integer[][]
local function fold(winid, folds)
  api.nvim_win_call(winid, function()
    vim.wo[winid].foldmethod = "manual"
    vim.cmd "silent! normal! zE"
    for _, range in ipairs(folds) do
      vim.cmd(("silent %d,%dfold"):format(range[1], range[2]))
    end
    vim.wo[winid].foldenable = true
    vim.wo[winid].foldlevel = 0
    vim.wo[winid].foldtext = "v:lua.require'plugins.git.history'.foldtext()"
  end)
end

---@param view table
---@param diff table
local function apply(view, diff)
  local layout, state = view.cur_layout, state_of(view)
  if not (layout and diff.hunks and #diff.hunks > 0) then return end
  for symbol, side in pairs { a = "old", b = "new" } do
    local window = layout[symbol]
    if showing_its_file(window) then
      local count = api.nvim_buf_line_count(window.file.bufnr)
      fold(window.id, state.full and {} or folds_outside(diff.hunks, side, state.context, count))
    end
  end
end

---@param view table
---@return table? window, "old"|"new"|nil side
local function main_window(view)
  local layout = view.cur_layout
  if not layout then return nil end
  if showing_its_file(layout.b) then return layout.b, "new" end
  if showing_its_file(layout.a) then return layout.a, "old" end
end

-- The cursor stays where it is unless a fold has just swallowed it.
---@param view table
---@param diff table
---@param keep boolean
local function focus_range(view, diff, keep)
  local window, side = main_window(view)
  local hunk = diff.hunks and diff.hunks[1]
  if not (window and side and hunk) then return end
  api.nvim_win_call(window.id, function()
    if not (keep and vim.fn.foldclosed(vim.fn.line ".") == -1) then
      local first = span(hunk[side .. "_row"], hunk[side .. "_size"])
      api.nvim_win_set_cursor(window.id, { math.min(first, api.nvim_buf_line_count(window.file.bufnr)), 0 })
    end
    vim.cmd "normal! zz"
  end)
end

---@param state git.history.State
---@return string
local function describe(state)
  if state.full then return "Showing the whole file" end
  if state.context == 0 then return "Showing only the traced lines" end
  return ("Showing the traced lines with %d lines of context"):format(state.context)
end

---@param change fun(state: git.history.State)
local function adjust(change)
  local view = current_view()
  local diff = traced_diff(view)
  if not (view and diff) then return say "Context only applies to the history of a line" end
  local state = state_of(view)
  change(state)
  apply(view, diff)
  focus_range(view, diff, true)
  say(describe(state))
end

function M.widen()
  adjust(function(state)
    if state.full then
      state.full = false
    else
      state.context = state.context + STEP
    end
  end)
end

function M.narrow()
  adjust(function(state)
    state.full = false
    state.context = math.max(0, state.context - STEP)
  end)
end

function M.toggle_full()
  adjust(function(state) state.full = not state.full end)
end

---@param bufnr integer
local function map_keys(bufnr)
  local function map(lhs, rhs, desc) vim.keymap.set("n", lhs, rhs, { buffer = bufnr, nowait = true, desc = desc }) end
  map("+", M.widen, "Show 10 more lines around the traced lines")
  map("-", M.narrow, "Show 10 fewer lines around the traced lines")
  map("=", M.toggle_full, "Toggle between the traced lines and the whole file")
end

---@return string
function M.foldtext() return ("  ··· %d lines ···"):format(vim.v.foldend - vim.v.foldstart + 1) end

---@return boolean
function M.active() return traced_diff(current_view()) ~= nil end

-- Called after `hud.dress`, which opens every fold in every pane it dresses.
---@param bufnr integer
function M.dress(bufnr)
  local view = current_view()
  local diff = traced_diff(view)
  if not (view and diff) then return end
  map_keys(bufnr)
  apply(view, diff)
end

-- Diffview builds its own zero-context patch folds after the panes open, the
-- first time each commit is shown, so ours are laid again once it has finished.
---@param view table
function M.watch(view)
  if not (view and view.emitter) then return end
  view.emitter:on("file_open_post", function()
    local diff = traced_diff(view)
    if not diff then return end
    apply(view, diff)
    focus_range(view, diff, false)
  end)
end

return M
