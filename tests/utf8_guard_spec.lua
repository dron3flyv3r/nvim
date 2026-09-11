local guard = require "user.utf8_guard"

local function same(actual, expected, label)
  assert(
    vim.deep_equal(actual, expected),
    ("%s: expected %s, got %s"):format(label, vim.inspect(expected), vim.inspect(actual))
  )
end

-- Valid sequences must stay valid, or the guard would eat real text. The Danish
-- letters and the box-drawing rule are the two that actually appear in the
-- Unity sources this was written for.
same(guard.invalid_offsets "plain ascii", {}, "ascii")
same(guard.invalid_offsets "æøå ÆØÅ", {}, "danish letters")
same(guard.invalid_offsets "a — b", {}, "em dash")
same(guard.invalid_offsets "───", {}, "box drawing")
same(guard.invalid_offsets "\240\159\152\128", {}, "four-byte codepoint")

-- The shapes seen in the crash log: a lone lead byte, an orphaned continuation
-- byte, and a sequence cut short by the end of the line.
same(guard.invalid_offsets "lone lead \195", { 11 }, "lone c3")
same(guard.invalid_offsets "orphan \187 cont", { 8 }, "orphan bb")
same(guard.invalid_offsets "lone \226 lead", { 6 }, "lone e2")
same(guard.invalid_offsets "truncated \226\128", { 11, 12 }, "truncated three-byte")

-- Overlong forms, surrogate halves and codepoints past U+10FFFF are all
-- rejected by `System.Text.Json`, so reporting them as clean would still cost
-- the server.
same(guard.invalid_offsets "\192\175", { 1, 2 }, "overlong two-byte")
same(guard.invalid_offsets "\237\160\128", { 1, 2, 3 }, "utf-16 surrogate half")
same(guard.invalid_offsets "\245\128\128\128", { 1, 2, 3, 4 }, "past U+10FFFF")

-- An edit landing inside a character leaves both halves broken.
same(guard.invalid_offsets "\195X\131", { 1, 3 }, "split character")

local stripped, removed = guard.strip "keep æ drop \195 end"
same({ stripped, removed }, { "keep æ drop  end", 1 }, "strip keeps valid multibyte")
same({ guard.strip "nothing to do" }, { "nothing to do", 0 }, "strip leaves clean text alone")

-- What goes on the wire. The masked string has to match the buffer's own byte
-- and UTF-16 lengths, or the server's copy of the line drifts out of step and
-- it starts handing back edits computed against text the buffer does not have.
local original = "keep æ mask \195 end"
local masked, count = guard.mask(original)
same({ masked, count }, { "keep æ mask ? end", 1 }, "mask substitutes rather than deletes")
same(#masked, #original, "mask preserves byte length")
same(vim.str_utfindex(masked, "utf-16"), vim.str_utfindex(original, "utf-16"), "mask preserves utf-16 length")
same(guard.invalid_offsets(masked), {}, "masked text is valid utf-8")

local multi = "\195 a \187 b \226"
local multi_masked, multi_count = guard.mask(multi)
same({ multi_masked, multi_count }, { "? a ? b ?", 3 }, "mask handles several bytes on one line")
same(#multi_masked, #multi, "mask preserves length with several bytes")
same({ guard.mask "already clean" }, { "already clean", 0 }, "mask leaves clean text alone")

local buffer = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buffer, 0, -1, false, {
  "clean",
  "a \195 b",
  "c \187 d \226 e",
  "æøå",
})
same(guard.fix(buffer), 3, "fix removes every invalid byte")
same(guard.scan(buffer), {}, "buffer is clean afterwards")
same(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), {
  "clean",
  "a  b",
  "c  d  e",
  "æøå",
}, "fix leaves valid text untouched")
same(guard.fix(buffer), 0, "fix on a clean buffer is a no-op")

-- `scan` is given only the changed lines by `on_lines`, so the range has to
-- report line numbers in the buffer's own terms rather than the slice's.
same(guard.scan(buffer, 0, 1), {}, "range scan of a clean line")
vim.api.nvim_buf_set_lines(buffer, 2, 3, false, { "bad \195 here" })
same(guard.scan(buffer, 2, 3), { { lnum = 3, col = 5, bytes = "c3" } }, "range scan reports absolute lines")

print "utf8_guard_spec: all assertions passed"
