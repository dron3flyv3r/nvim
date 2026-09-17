local hover = require "user.hover"

local function same(actual, expected, label)
  assert(
    vim.deep_equal(actual, expected),
    ("%s: expected %s, got %s"):format(label, vim.inspect(expected), vim.inspect(actual))
  )
end

-- The shapes roslyn_ls actually sends. Entities are its indentation for
-- `<returns>` bodies, and it escapes punctuation that CommonMark never needed
-- escaping in the first place.
same(hover.sanitize "Makes the widget go\\.", "Makes the widget go.", "escaped period")
same(hover.sanitize "widget\\-shaped work", "widget-shaped work", "escaped hyphen mid-line")
same(hover.sanitize "&nbsp;&nbsp;The distance travelled\\.", "  The distance travelled.", "nbsp indentation")
same(hover.sanitize "a &lt;T&gt; b &amp; c", "a <T> b & c", "angle and ampersand entities")
same(hover.sanitize "&#65;bc", "Abc", "numeric entity")

-- Escapes that are load-bearing: unescaping these would turn documentation into
-- emphasis, code spans or links.
same(hover.sanitize "a \\*literal\\* star", "a \\*literal\\* star", "emphasis stays escaped")
same(hover.sanitize "an \\_underscore\\_", "an \\_underscore\\_", "underscore stays escaped")
same(hover.sanitize "a \\`backtick\\`", "a \\`backtick\\`", "code span stays escaped")
same(hover.sanitize "not a \\[link\\]", "not a \\[link\\]", "link stays escaped")

-- Leading position is what makes these structural; mid-line they are not.
same(hover.sanitize "\\- not a list", "\\- not a list", "leading hyphen stays escaped")
same(hover.sanitize "\\# not a heading", "\\# not a heading", "leading hash stays escaped")
same(hover.sanitize "see item \\# 4", "see item # 4", "hash mid-line is unescaped")

-- Code fences carry real backslashes -- a Rust `\n` must survive intact.
same(hover.sanitize '```rust\nprintln!("a\\nb");\n```', '```rust\nprintln!("a\\nb");\n```', "fenced code is left alone")
same(
  hover.sanitize "```cs\nint x;\n```\ndocs go\\.",
  "```cs\nint x;\n```\ndocs go.",
  "prose after a fence is still sanitized"
)

-- `has_prose` is the trigger for the class-docs fallback: a bare constructor
-- signature has none, a documented one does. Getting this wrong either fires a
-- pointless second request or misses the case the fallback exists for.
assert(not hover.has_prose "```csharp\nWidget.Widget()\n```\n  \n", "bare constructor has no prose")
assert(not hover.has_prose "```csharp\nx\n```\n&nbsp;&nbsp;\n", "entity-only padding is not prose")
assert(
  hover.has_prose "```csharp\nGadget.Gadget(string name)\n```\n  \nBuilds a gadget\\.  \n",
  "documented constructor has prose"
)
assert(hover.has_prose "plain text with no fence at all", "unfenced text is prose")

-- The float options are shared with rustaceanvim, so the keys it forwards to
-- `open_floating_preview` have to keep existing.
local opts = hover.float_opts()
for _, key in ipairs { "border", "title", "max_width", "max_height", "wrap" } do
  assert(opts[key] ~= nil, "float_opts is missing " .. key)
end
assert(opts.max_width > 0 and opts.max_height > 0, "float_opts must produce a usable size")
