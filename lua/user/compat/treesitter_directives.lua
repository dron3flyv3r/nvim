local M = {}

local applied = false

---@param match table<integer, TSNode|TSNode[]>
---@return table<integer, TSNode>
local function unwrap(match)
  local single = {}
  for id, captured in pairs(match) do
    single[id] = type(captured) == "table" and captured[1] or captured
  end
  return single
end

--- Wrap `vim.treesitter.query.add_directive` / `add_predicate` so handlers
--- registered with `all = false` keep getting what they asked for.
function M.setup()
  if applied then return end
  applied = true

  local query = require "vim.treesitter.query"
  for _, register in ipairs { "add_directive", "add_predicate" } do
    local original = query[register]
    query[register] = function(name, handler, opts)
      if type(opts) == "table" and opts.all == false then
        local legacy = handler
        -- Only `match` changes shape; `pattern`, `source`, the predicate and
        -- the metadata table are passed straight through, so directives still
        -- write their results where the caller reads them.
        handler = function(match, ...) return legacy(unwrap(match), ...) end
      end
      return original(name, handler, opts)
    end
  end
end

return M
