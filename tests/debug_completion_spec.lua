local completion = require "user.debug.completion"

---@param text string
---@param expected string|nil
local function base(text, expected)
  local actual = completion.base(text)
  assert(actual == expected, ("base(%q): expected %s, got %s"):format(text, vim.inspect(expected), vim.inspect(actual)))
end

-- A bare name is not a member access: the candidates come from the frame, not
-- from evaluating anything.
base("", nil)
base("_fe", nil)
base("grounded", nil)

base("_feet.", "_feet")
base("_feet.pos", "_feet")
base("this._velocity.", "this._velocity")
base("this._velocity.mag", "this._velocity")

-- Evaluating the whole line would be wrong, and on a live process potentially
-- expensive: only the chain the cursor is actually inside gets asked about.
base("Mathf.Sqrt(x.y", "x")
base("foo(bar.baz.qu", "bar.baz")

-- Indexers are part of the chain; the adapter can evaluate them.
base("arr[0].na", "arr[0]")
