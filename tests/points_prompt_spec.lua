-- Run with: nvim --headless -u NONE -l tests/points_prompt_spec.lua
local original_vim = vim
local original_points = package.loaded["user.points"]
local original_astrocore = package.loaded["astrocore"]

---A world just real enough for the float: a key waiting to be read, a set of
---points to list, and a record of what was drawn, run and handed back.
---@param world table?
local function stub(world)
  world = world or {}
  local state = { drawn = {}, spans = {}, commands = {}, fed = {}, notified = {}, closed = 0, deferred = {} }
  local cmd = setmetatable({ redraw = function() end }, {
    __call = function(_, command)
      table.insert(state.commands, command)
      if world.unset then error("Vim:E20: Mark not set", 0) end
    end,
  })
  vim = setmetatable({
    api = setmetatable({
      nvim_create_namespace = function() return 1 end,
      nvim_get_hl = function() return { bg = 0, fg = 0 } end,
      nvim_set_hl = function() end,
      nvim_create_buf = function() return 3 end,
      nvim_buf_is_valid = function() return true end,
      nvim_buf_set_lines = function(_, _, _, _, lines)
        table.insert(state.drawn, lines[1])
        state.spans[#state.drawn] = {}
      end,
      nvim_buf_clear_namespace = function() end,
      nvim_buf_set_extmark = function(_, _, _, col, opts)
        table.insert(state.spans[#state.drawn], { col, opts.end_col })
      end,
      nvim_open_win = function() return 9 end,
      nvim_win_is_valid = function() return true end,
      nvim_win_set_config = function() end,
      nvim_win_close = function() state.closed = state.closed + 1 end,
      nvim_win_get_height = function() return 40 end,
      nvim_feedkeys = function(keys) table.insert(state.fed, keys) end,
    }, { __index = original_vim.api }),
    fn = {
      getcharstr = function() return world.key or "q" end,
      winline = function() return 5 end,
      strdisplaywidth = function(s) return #s end,
    },
    bo = setmetatable({}, { __index = function() return {} end }),
    wo = setmetatable({}, { __index = function() return {} end }),
    cmd = cmd,
    defer_fn = function(fn) table.insert(state.deferred, fn) end,
  }, { __index = original_vim })
  package.loaded["astrocore"] = { notify = function(message) table.insert(state.notified, message) end }
  package.loaded["user.points"] = {
    order = world.order or {},
    set = function(letter) state.set = letter end,
  }
  return state, dofile "lua/user/points/prompt.lua"
end

local ok, err = pcall(function()
  -- The prompt names what it is waiting for and lists the letters taken.
  do
    local state, prompt = stub { order = { "q", "w" } }
    prompt.mark()
    assert(state.drawn[1] == " point  q w ", "the pending prompt lists the taken letters: " .. state.drawn[1])
    assert(#state.spans[1] == 2, "each letter is highlighted")
    assert(state.set == "q", "the typed letter is stored")
  end

  -- Nothing stored yet: say so rather than showing an empty strip.
  do
    local state, prompt = stub()
    prompt.mark()
    assert(state.drawn[1] == " point  nothing set ", "the empty set is named: " .. state.drawn[1])
  end

  -- Storing confirms in place, and the confirmation says whether it moved.
  do
    local state, prompt = stub()
    prompt.mark()
    assert(state.drawn[2] == " point q set ", "a new point is confirmed: " .. state.drawn[2])
    local moved = stub { order = { "q" } }
    dofile("lua/user/points/prompt.lua").mark()
    assert(moved.drawn[2] == " point q moved here ", "a re-set point says it moved: " .. moved.drawn[2])
  end

  -- The confirmation clears itself, unless a newer prompt took the float over.
  do
    local state, prompt = stub()
    prompt.mark()
    local closes = state.closed
    state.deferred[1]()
    assert(state.closed == closes + 1, "the confirmation is cleared")
    prompt.mark()
    local after = state.closed
    state.deferred[1]()
    assert(state.closed == after, "an older timer does not close a newer prompt")
  end

  -- Dismissing leaves no point and no keys behind.
  do
    for _, key in ipairs { "\27", "\3", "" } do
      local state, prompt = stub { key = key }
      prompt.mark()
      assert(state.set == nil and #state.fed == 0, "dismissed with " .. vim.inspect(key))
      assert(state.closed > 0, "the prompt is taken down")
    end
  end

  -- Anything that is not a lowercase letter goes back to Neovim unmapped.
  do
    local state, prompt = stub { key = "A" }
    prompt.mark()
    assert(state.fed[1] == "mA", "uppercase falls through to native: " .. vim.inspect(state.fed[1]))
    local dotted, jumper = stub { key = "." }
    jumper.jump()
    assert(dotted.fed[1] == "'.", "'. falls through to native: " .. vim.inspect(dotted.fed[1]))
  end

  -- Jumping prompts too, and runs the uppercase twin of the letter.
  do
    local state, prompt = stub { order = { "q" } }
    prompt.jump()
    assert(state.drawn[1] == " go to  q ", "the jump prompt lists the points: " .. state.drawn[1])
    assert(state.commands[1] == "normal! 'Q", "the jump runs against the global mark")
  end

  -- A letter with nothing behind it is reported rather than left to E20.
  do
    local state, prompt = stub { unset = true }
    prompt.jump()
    assert(#state.notified == 1 and state.notified[1]:match "not set", "an unset point is reported")
  end

  -- Visual and operator-pending translate without a prompt: a float there is
  -- E565, so these only hand the operator its motion.
  do
    local state, prompt = stub()
    assert(prompt.motion() == "'Q", "a letter becomes its global twin")
    assert(#state.drawn == 0, "no float is drawn for a motion")
    stub { key = "." }
    assert(dofile("lua/user/points/prompt.lua").motion() == "'.", "non-letters pass through")
  end
end)

vim = original_vim
package.loaded["user.points"] = original_points
package.loaded["astrocore"] = original_astrocore
assert(ok, err)
print "Points prompt regression checks passed"
