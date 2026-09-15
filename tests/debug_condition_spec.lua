local condition = require "user.debug.condition"

---@param text string
local function accepts(text)
  local complaint = condition.lint(text)
  assert(complaint == nil, ("lint(%q): expected no complaint, got %q"):format(text, tostring(complaint)))
end

---@param text string
---@param expected string a fragment of the complaint
local function refuses(text, expected)
  local complaint = condition.lint(text)
  assert(complaint, ("lint(%q): expected a complaint, got none"):format(text))
  assert(
    complaint:find(expected, 1, true),
    ("lint(%q): expected a complaint mentioning %q, got %q"):format(text, expected, complaint)
  )
end

accepts "_airJumps > 0"
accepts "grounded == false"
accepts "_feet.position.y <= 0.1 && _airJumps != maxAirJumps"
accepts 'name == "a=b"'
accepts "items.Any(x => x.Id == 4)"
accepts "count >= 3"

refuses("", "empty")
refuses("   ", "empty")

-- The mistake this exists for: a condition that assigns compiles in some
-- languages, is rejected in others, and is never what was meant.
refuses("_airJumps = 1", "did you mean `==`")

refuses("Physics.CheckSphere(_feet.position", "`(` is never closed")
refuses("_airJumps > 0)", "nothing to close")
refuses('name == "unterminated', "never closed")
refuses("_airJumps >", "ends with `>`")
refuses("grounded &&", "ends with `&`")
