-- Reading diagnostics: the one under the cursor, all of them, and a filter for
-- the ones you do not care about right now.
--
-- WHAT NEOVIM ALREADY GIVES YOU, AND WHERE IT STOPS.
--
--   * `vim.diagnostic.open_float()` shows the messages on the current line in a
--     popup -- and that popup is *not* focusable as configured, so a long
--     message is truncated at the window edge with no way to scroll it. Roslyn
--     and basedpyright both routinely emit type errors longer than the screen
--     is wide (a generic C# signature is a paragraph), so "I can see there is
--     an error but not what it says" is the normal case, not the edge case.
--     `M.float` passes `focus = true`, which makes the second press *enter* the
--     popup: then it is an ordinary window and `j`, `<C-d>`, `/` and `y` all
--     work, and `q` closes it.
--
--   * `vim.diagnostic.setqflist()` lists all of them -- in the quickfix list,
--     which is the same flat strip with no fuzzy filter and no preview that
--     made `<Leader>lR` feel worse than grep. Those keys are still there under
--     `<Leader>x`, but `M.picker` sends the same data to snacks instead, so
--     "list every error" lands in the window `<Leader>ff` uses.
--
--   * Nothing filters by severity. `vim.diagnostic.config` accepts a `severity`
--     on each renderer, but it is a config edit, not a toggle -- and the four
--     renderers have to be kept in step or you get signs in the gutter for
--     hints whose text is hidden.
--
-- THE FILTER IS ONE PIECE OF STATE, READ BY EVERYTHING. `M.min_severity` is
-- nil (show all) or `ERROR` (errors only), and it drives the virtual text, the
-- underline, the signs, the pickers *and* the `]d` / `æd` jumps. That last one
-- is the whole point: a filter that hides hints but still stops on them when
-- you walk the list has not hidden anything, it has just made them invisible.

local M = {}

--- The lowest severity that is allowed to be seen, or nil for "all of them".
--- `ERROR` is 1 and `HINT` is 4, so this is a *maximum* number and reads
--- backwards; `severity_filter` below does the translating.
---@type integer|nil
M.min_severity = nil

--- The `severity` value to hand `vim.diagnostic.get` / the snacks pickers.
---@return vim.diagnostic.SeverityFilter|nil
function M.severity_filter() return M.min_severity and { min = M.min_severity } or nil end

--- The renderers that have to agree with each other. `float` is deliberately
--- absent: a popup you asked for by pressing a key is not noise, and hiding
--- half of what is wrong with the line you are looking at would be a bug
--- dressed up as a feature.
local RENDERERS = { "virtual_text", "virtual_lines", "underline", "signs" }

--- What each renderer looked like before we touched it, so that switching the
--- filter off restores exactly that. Without this, a renderer configured as
--- plain `true` comes back as `{}` -- which every renderer here happens to read
--- the same way, but it means the config no longer round-trips, and the next
--- person to `:lua =vim.diagnostic.config()` has to work out why.
---@type table<string, any>
local unfiltered = {}

--- Push `M.min_severity` into `vim.diagnostic.config`.
---
--- Each renderer is rewritten rather than merged into, because turning the
--- filter *off* means the `severity` key has to be *gone*, and `tbl_extend`
--- cannot express "remove this key".
---
--- A renderer that is switched off entirely (`false`, or absent) is left alone
--- in both directions, so this composes with AstroNvim's own `<Leader>ud` /
--- `<Leader>uv` toggles rather than fighting them: if virtual text was turned
--- off while the filter was on, switching the filter off leaves it off.
local function apply()
  local current = vim.diagnostic.config() or {}
  local severity = M.severity_filter()
  local update = {}

  for _, renderer in ipairs(RENDERERS) do
    local value = current[renderer]

    if not severity then
      local saved = unfiltered[renderer]
      unfiltered[renderer] = nil
      -- Undo our own edit and nothing else: a value that is no longer a
      -- filtered table is somebody else's doing now.
      if saved ~= nil and type(value) == "table" and value.severity ~= nil then update[renderer] = saved end
    elseif value == true or type(value) == "table" then
      -- Captured on the way in only. Filtering twice in a row without an
      -- intervening un-filter would otherwise save the already-filtered table
      -- as the thing to restore.
      if unfiltered[renderer] == nil then unfiltered[renderer] = vim.deepcopy(value) end
      local filtered = type(value) == "table" and vim.deepcopy(value) or {}
      filtered.severity = severity
      update[renderer] = filtered
    end
  end

  vim.diagnostic.config(update)
end

--- Show everything, or only errors.
function M.toggle()
  -- Spelled out rather than `x and nil or y`, which in Lua always evaluates to
  -- `y`: `x and nil` is nil, and `nil or y` is y. The filter would never switch
  -- back off.
  if M.min_severity then
    M.min_severity = nil
  else
    M.min_severity = vim.diagnostic.severity.ERROR
  end
  apply()

  if not M.min_severity then
    vim.notify("Showing all diagnostics", vim.log.levels.INFO, { title = "Diagnostics" })
    return
  end

  -- Counted in this buffer rather than the whole session: the number is there
  -- to tell you what just disappeared from the screen in front of you.
  local hidden = #vim.diagnostic.get(0, { severity = { min = vim.diagnostic.severity.WARN } })
  vim.notify(
    hidden > 0 and ("Errors only  (%d hidden in this buffer)"):format(hidden) or "Errors only",
    vim.log.levels.INFO,
    { title = "Diagnostics" }
  )
end

--- Open the diagnostics on the cursor's line; press again to step into them.
---
--- The three presses cycle show -> focus -> back, which is
--- `open_floating_preview`'s own behaviour once `focus` is set; the only part
--- that is ours is noticing we are already inside the popup, because otherwise
--- the "nothing here" check below fires on the popup's own empty buffer and the
--- third press does nothing.
function M.float()
  if vim.api.nvim_win_get_config(0).relative ~= "" then
    vim.cmd.wincmd "p"
    return
  end

  local lnum = vim.api.nvim_win_get_cursor(0)[1] - 1
  local on_line = vim.diagnostic.get(0, { lnum = lnum })
  if vim.tbl_isempty(on_line) then
    vim.notify("Nothing wrong on this line", vim.log.levels.INFO, { title = "Diagnostics" })
    return
  end

  -- Everything on the line is shown, filter or no filter -- but say so, or a
  -- popup listing four things while the gutter shows one looks like a bug.
  local hidden = 0
  if M.min_severity then
    for _, diagnostic in ipairs(on_line) do
      if diagnostic.severity > M.min_severity then hidden = hidden + 1 end
    end
  end

  vim.diagnostic.open_float {
    scope = "line",
    focus = true,
    header = hidden > 0 and { ("Diagnostics:  (%d hidden by the errors-only filter)"):format(hidden), "Bold" }
      or { "Diagnostics:", "Bold" },
  }
end

--- Every diagnostic, in the `<Leader>ff` picker.
---
--- The project-wide source is cwd-filtered by snacks' own default, which is
--- what you want: without it a single open file from a `Library/PackageCache`
--- or a `site-packages` drags its whole dependency's worth of hints in.
---@param scope? "buffer" Defaults to the whole project.
function M.picker(scope)
  local picker = require("snacks").picker
  local opts = { severity = M.severity_filter() }
  if scope == "buffer" then
    picker.diagnostics_buffer(opts)
  else
    picker.diagnostics(opts)
  end
end

--- Jump to the next/previous diagnostic the filter is not hiding.
---@param count integer Negative goes backwards. `vim.v.count1` for `3æd`.
function M.jump(count)
  local target = vim.diagnostic.jump { count = count, severity = M.severity_filter(), float = false }
  if not target then
    vim.notify(
      M.min_severity and "No more errors" or "No more diagnostics",
      vim.log.levels.INFO,
      { title = "Diagnostics" }
    )
  end
end

return M
