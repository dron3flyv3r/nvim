--- Marks that can be reached on a Danish layout. The jump key Vim documents is
--- `` ` ``, which on this layout is Shift on the dead `´` key -- Shift+´ then
--- `a` composes `à` rather than jumping anywhere. `'` sits unshifted next to
--- `ø` and is live, so it carries the jumps here.
---
--- `m<letter>` and `'<letter>` keep their native spelling; the only change is
--- that the mark is promoted to its uppercase twin, which is global, so a point
--- set in one file is reachable from another. That is the whole trick -- these
--- are ordinary marks, listed by `:marks` and cleared by `:delmarks`, and the
--- jumps stay native keys so operators still compose (`d'q`, `y'q`).
---
--- The cost of promoting every letter is that marks stop being per-buffer:
--- `ma` names one point across the session rather than one per file.
local M = {}

--- Letters holding a point, in the order they were first set. Re-setting a
--- letter keeps its place, so walking the set does not reshuffle under you.
---@type string[]
M.order = {}

---@param letter string lowercase; the point is stored in its uppercase twin
function M.set(letter)
  vim.cmd("normal! m" .. letter:upper())
  if not vim.tbl_contains(M.order, letter) then table.insert(M.order, letter) end
end

--- Points last one session. Whatever shada restored is dropped at startup
--- rather than left to accumulate across unrelated projects.
function M.clear()
  vim.cmd "delmarks A-Z"
  M.order = {}
end

---@class UserPoint
---@field letter string
---@field path string
---@field line integer

--- The points that still resolve, in walk order. A mark whose file is gone
--- comes back with row 0; those are skipped rather than walked into.
---@return UserPoint[]
function M.list()
  local points = {}
  for _, letter in ipairs(M.order) do
    local mark = vim.api.nvim_get_mark(letter:upper(), {})
    if mark[1] > 0 then points[#points + 1] = { letter = letter, path = mark[4], line = mark[1] } end
  end
  return points
end

--- Where the cursor is sitting, as an index into `points`. Read from the
--- cursor rather than remembered, so walking still makes sense after a jump
--- that went through `'<letter>` without touching this module.
---@param points UserPoint[]
---@return integer?
local function here(points)
  local path = vim.api.nvim_buf_get_name(0)
  if path == "" then return nil end
  path = vim.fn.fnamemodify(path, ":p")
  local line = vim.api.nvim_win_get_cursor(0)[1]
  for index, point in ipairs(points) do
    if point.line == line and vim.fn.fnamemodify(point.path, ":p") == path then return index end
  end
  return nil
end

--- Walk to the next (`step` 1) or previous (`step` -1) point, wrapping around.
--- Off a point, the walk enters the set at the near end, so the first press
--- always lands somewhere.
---@param step integer
function M.walk(step)
  local points = M.list()
  if #points == 0 then
    return require("astrocore").notify(
      "No points set -- m<letter> stores one",
      vim.log.levels.INFO,
      { title = "Points" }
    )
  end
  local index = here(points)
  index = index and (index - 1 + step) % #points + 1 or (step > 0 and 1 or #points)
  vim.cmd("normal! '" .. points[index].letter:upper())
end

return M
