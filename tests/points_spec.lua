-- Run with: nvim --headless -u NONE -l tests/points_spec.lua
local original_vim = vim
local original_astrocore = package.loaded["astrocore"]

local FILE, OTHER = "/tmp/points-a.lua", "/tmp/points-b.lua"

---A world just real enough for the module: a set of global marks, a cursor
---somewhere, and a record of the `normal!` commands that were run.
---@param world table?
local function stub(world)
  world = world or {}
  local state = { commands = {}, notified = {} }
  vim = setmetatable({
    -- Only the calls the module makes are replaced; the rest of `api` stays
    -- real, because Neovim's own module loader goes through it.
    api = setmetatable({
      nvim_get_mark = function(name)
        local mark = (world.marks or {})[name]
        if not mark then return { 0, 0, 0, "" } end
        return { mark.line, 0, 1, mark.path }
      end,
      nvim_buf_get_name = function() return world.buffer or "" end,
      nvim_win_get_cursor = function() return { world.line or 1, 0 } end,
    }, { __index = original_vim.api }),
    fn = { fnamemodify = function(path) return path end },
    cmd = function(command) table.insert(state.commands, command) end,
  }, { __index = original_vim })
  package.loaded["astrocore"] = {
    notify = function(message) table.insert(state.notified, message) end,
  }
  -- Loaded rather than required, so each case gets its own module state.
  return state, dofile "lua/user/points.lua"
end

local ok, err = pcall(function()
  -- Setting a point writes the uppercase -- global -- twin of the letter.
  do
    local state, points = stub()
    points.set "q"
    assert(state.commands[1] == "normal! mQ", "set writes the uppercase mark")
    assert(#points.order == 1 and points.order[1] == "q", "the letter is recorded")
  end

  -- Re-setting a letter keeps its place, so the walk order stays put.
  do
    local _, points = stub()
    points.set "q"
    points.set "w"
    points.set "q"
    assert(#points.order == 2, "a letter is recorded once")
    assert(points.order[1] == "q" and points.order[2] == "w", "first-set order is kept")
  end

  -- `m` and `'` are mapped whole, so nothing waits out `timeoutlen` and the
  -- prompt has somewhere to appear. Visual and operator-pending have to be
  -- expressions, because that is the only shape an operator can consume.
  do
    stub()
    local opts = { mappings = { n = {} } }
    dofile("lua/plugins/points.lua").opts(nil, opts)
    assert(type(opts.mappings.n.m[1]) == "function", "m reads its own letter")
    assert(type(opts.mappings.n["'"][1]) == "function", "' reads its own letter")
    assert(opts.mappings.n["'"].expr == nil, "normal mode can open the prompt")
    for _, mode in ipairs { "x", "o" } do
      assert(opts.mappings[mode]["'"].expr == true, mode .. ": the motion is an expression")
    end
    assert(opts.mappings.n.mq == nil and opts.mappings.n["'q"] == nil, "no per-letter mappings remain")
  end

  -- Off a point, walking enters the set at the near end.
  do
    local state, points = stub {
      marks = { Q = { line = 10, path = FILE }, W = { line = 20, path = OTHER } },
      buffer = FILE,
      line = 99,
    }
    points.order = { "q", "w" }
    points.walk(1)
    assert(state.commands[1] == "normal! 'Q", "forward enters at the first point")
    points.walk(-1)
    assert(state.commands[2] == "normal! 'W", "backward enters at the last point")
  end

  -- On a point, walking continues from it and wraps around.
  do
    local state, points = stub {
      marks = { Q = { line = 10, path = FILE }, W = { line = 20, path = OTHER } },
      buffer = OTHER,
      line = 20,
    }
    points.order = { "q", "w" }
    points.walk(1)
    assert(state.commands[1] == "normal! 'Q", "forward from the last point wraps to the first")
    points.walk(-1)
    assert(state.commands[2] == "normal! 'Q", "backward from the last point steps to the first")
  end

  -- A point whose file is gone comes back with row 0 and is not walked into.
  do
    local state, points = stub { marks = { W = { line = 20, path = OTHER } }, buffer = FILE, line = 1 }
    points.order = { "q", "w" }
    assert(#points.list() == 1, "an unset mark is dropped from the list")
    points.walk(1)
    assert(state.commands[1] == "normal! 'W", "the walk skips it")
  end

  -- Nothing set: say so rather than jumping somewhere arbitrary.
  do
    local state, points = stub()
    points.walk(1)
    assert(#state.commands == 0, "no jump is made")
    assert(#state.notified == 1, "the empty set is reported")
  end

  -- One session: startup drops whatever shada restored.
  do
    local state, points = stub()
    points.order = { "q" }
    points.clear()
    assert(state.commands[1] == "delmarks A-Z", "the global marks are cleared")
    assert(#points.order == 0, "the walk order is cleared with them")
  end
end)

vim = original_vim
package.loaded["astrocore"] = original_astrocore
assert(ok, err)
print "Points regression checks passed"
