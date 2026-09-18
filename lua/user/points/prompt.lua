--- What `m` is waiting for. A macro can announce itself with `recording @q`
--- because it records for a while; a point is one keystroke, so the only
--- moment to say anything is between `m` and the letter -- which is also the
--- moment to show which letters are already taken. `cmdheight = 0` makes any
--- echo force the message area open and shove the statusline, so this is a
--- float at the cursor instead.
local M = {}

local api = vim.api
local NS = api.nvim_create_namespace "user_points_prompt"
local win, buf, generation = nil, nil, 0

local function highlights()
  local normal = api.nvim_get_hl(0, { name = "Normal", link = false })
  local comment = api.nvim_get_hl(0, { name = "Comment", link = false })
  local special = api.nvim_get_hl(0, { name = "Special", link = false })
  api.nvim_set_hl(0, "PointsPrompt", { bg = normal.bg, fg = comment.fg })
  api.nvim_set_hl(0, "PointsPromptKey", { bg = normal.bg, fg = special.fg, bold = true })
end

local function close()
  if win and api.nvim_win_is_valid(win) then api.nvim_win_close(win, true) end
  win = nil
end

---@param label string
---@return string line, integer[][] the columns holding a letter
local function compose(label)
  local order = require("user.points").order
  if #order == 0 then return " " .. label .. "  nothing set ", {} end
  local line, spans = " " .. label .. "  ", {}
  for _, letter in ipairs(order) do
    spans[#spans + 1] = { #line, #line + #letter }
    line = line .. letter .. " "
  end
  return line, spans
end

---@param line string
---@param spans integer[][]
local function draw(line, spans)
  highlights()
  if not (buf and api.nvim_buf_is_valid(buf)) then
    buf = api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "hide"
  end
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, { line })
  vim.bo[buf].modifiable = false
  api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  for _, span in ipairs(spans) do
    api.nvim_buf_set_extmark(buf, NS, 0, span[1], { end_col = span[2], hl_group = "PointsPromptKey" })
  end

  -- Below the cursor, flipping above on the last row, so the letters appear
  -- where the eyes already are rather than at the edge of the screen.
  local config = {
    relative = "cursor",
    row = vim.fn.winline() < api.nvim_win_get_height(0) and 1 or -1,
    col = 0,
    width = vim.fn.strdisplaywidth(line),
    height = 1,
    style = "minimal",
    focusable = false,
    zindex = 200,
  }
  if win and api.nvim_win_is_valid(win) then
    api.nvim_win_set_config(win, config)
  else
    config.noautocmd = true
    win = api.nvim_open_win(buf, false, config)
  end
  vim.wo[win].winhighlight = "Normal:PointsPrompt"
  generation = generation + 1
  vim.cmd.redraw()
end

---The key typed at the prompt, or nil where it was dismissed.
---@param label string
---@return string?
local function ask(label)
  draw(compose(label))
  local ok, char = pcall(vim.fn.getcharstr)
  close()
  if not ok or char == "" or char == "\27" or char == "\3" then return nil end
  return char
end

---Says what was stored, where the prompt already stood, then gets out of the
---way. A later prompt takes the float over, so the timer checks it is still
---showing what it put there.
---@param letter string
---@param moved boolean whether the letter already held a point
function M.confirm(letter, moved)
  draw(" point " .. letter .. (moved and " moved here " or " set "), { { 7, 7 + #letter } })
  local shown = generation
  vim.defer_fn(function()
    if generation == shown then close() end
  end, 800)
end

---`m`: store a point under the next letter typed. Anything that is not a
---lowercase letter goes back to Neovim unmapped, so `mA` and the error for
---`m1` behave as they always did.
function M.mark()
  local char = ask "point"
  if not char then return end
  if not char:match "^[a-z]$" then return api.nvim_feedkeys("m" .. char, "n", false) end
  local points = require "user.points"
  local moved = vim.tbl_contains(points.order, char)
  points.set(char)
  M.confirm(char, moved)
end

---`'` in normal mode, which is the only mode that can carry the prompt.
function M.jump()
  local char = ask "go to"
  if not char then return end
  if not char:match "^[a-z]$" then return api.nvim_feedkeys("'" .. char, "n", false) end
  if not pcall(vim.cmd, "normal! '" .. char:upper()) then
    require("astrocore").notify("Point " .. char .. " is not set", vim.log.levels.INFO, { title = "Points" })
  end
end

---`'` in visual and operator-pending. A float cannot be opened here -- E565,
---the mapping has to be an expression for the operator to consume the motion
---it returns -- so these modes translate the letter without the prompt.
---@return string
function M.motion()
  local char = vim.fn.getcharstr()
  if char:match "^[a-z]$" then return "'" .. char:upper() end
  return "'" .. char
end

return M
