-- Run with: nvim --headless -u NONE -l tests/git_navigation_spec.lua
local original_vim = vim
local original_hud = package.loaded["user.diff_hud"]
local original_review = package.loaded["user.diff_review"]
local original_actions = package.loaded["diffview.actions"]

local ok, err = pcall(function()
  for _, case in ipairs {
    { name = "new file", lone = "new", ticks = 3, jumps = 1 },
    { name = "edited file", diff = true, ticks = 3, jumps = 1 },
    { name = "loading timeout", ticks = 30, jumps = 0 },
  } do
    for _, reverse in ipairs { false, true } do
      local callback, stops, closes, jumps, selections = nil, 0, 0, 0, 0
      local timer = {
        start = function(_, _, _, fn) callback = fn end,
        stop = function() stops = stops + 1 end,
        close = function()
          assert(closes == 0, "handle is already closing")
          closes = closes + 1
        end,
      }
      vim = setmetatable({
        uv = { new_timer = function() return timer end },
        wo = { diff = case.diff or false },
        api = { nvim_win_get_cursor = function() return { 1, 0 } end },
        fn = { diff_hlID = function() return 1 end },
        -- Capture the scheduled body to simulate callbacks queued before close.
        schedule_wrap = function(fn) return fn end,
        cmd = function(command)
          if command == "normal! gg" or command == "normal! G" then
            assert(command == (reverse and "normal! G" or "normal! gg"))
            jumps = jumps + 1
          end
        end,
      }, { __index = original_vim })
      package.loaded["user.diff_hud"] = { lone_kind = function() return case.lone end }
      package.loaded["user.diff_review"] = { install_close_command = function() end }
      local function select_entry() selections = selections + 1 end
      package.loaded["diffview.actions"] = {
        select_next_entry = function()
          assert(not reverse)
          select_entry()
        end,
        select_prev_entry = function()
          assert(reverse)
          select_entry()
        end,
      }

      local spec = dofile "lua/plugins/git.lua"
      local maps = spec[1].opts().keymaps.view
      local key = reverse and "N" or "n"
      for _, mapping in ipairs(maps) do
        if mapping[2] == key then mapping[3]() end
      end
      assert(callback and selections == 1, case.name .. ": select entry")
      for _ = 1, case.ticks do
        callback()
      end
      assert(stops == 1 and closes == 1, case.name .. ": close once")
      assert(jumps == case.jumps, case.name .. ": jump once when ready")
    end
  end
end)

vim = original_vim
package.loaded["user.diff_hud"] = original_hud
package.loaded["user.diff_review"] = original_review
package.loaded["diffview.actions"] = original_actions
assert(ok, err)
print "Git navigation regression checks passed"
