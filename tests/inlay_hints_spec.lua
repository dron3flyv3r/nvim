local matcher = require "user.inlay_hints.matcher"
local store = require "user.inlay_hints.store"
local syntax = require "user.inlay_hints.syntax"

local function same(actual, expected, label)
  assert(
    vim.deep_equal(actual, expected),
    ("%s: expected %s, got %s"):format(label, vim.inspect(expected), vim.inspect(actual))
  )
end

same(store.bucket { callees = { "Foo", 42, "" }, paths = { "generated", false } }, {
  callees = { "Foo" },
  paths = { "generated" },
}, "store normalization")

local real_store = store.path
local temporary_store = vim.fn.tempname()
store.path = temporary_store
assert(store.write {
  global = { callees = { "GlobalCall" }, paths = {} },
  projects = {
    ["/project"] = { callees = { "LocalCall" }, paths = { "generated" } },
  },
})
store.invalidate()
same(store.read(), {
  global = { callees = { "GlobalCall" }, paths = {} },
  projects = {
    ["/project"] = { callees = { "LocalCall" }, paths = { "generated" } },
  },
}, "store round trip")
vim.uv.fs_unlink(temporary_store)
store.path = real_store
store.invalidate()
matcher.invalidate()

same({ syntax.normalize "new Mathf.Lerp<float>" }, { "Mathf.Lerp", "Lerp" }, "generic constructor")
same({ syntax.normalize "println!" }, { "println", "println" }, "Rust macro")
assert(syntax.is_parameter_hint { kind = 2, label = "name:" })
assert(not syntax.is_parameter_hint { kind = 1, label = ": string" })
assert(syntax.is_parameter_hint { label = { { value = "name" }, { value = ":" } } })

local rules = {
  paths = {
    { text = "generated" },
    { text = "**/*.g.cs", glob = assert(vim.glob.to_lpeg "**/*.g.cs") },
  },
}
assert(matcher.path_ignored(rules, "/project/generated/file.cs", "generated/file.cs"))
assert(matcher.path_ignored(rules, "/project/src/model.g.cs", "src/model.g.cs"))
assert(not matcher.path_ignored(rules, "/project/src/model.cs", "src/model.cs"))

local previous = vim.api.nvim_get_current_buf()
local buffer = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buffer)
vim.bo[buffer].filetype = "lua"
vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "outer(1, inner(2))" })
local parser_ok = pcall(vim.treesitter.get_parser, buffer, "lua")
if parser_ok then
  same({ syntax.call_at(buffer, 0, 1, true) }, { "outer", "outer" }, "callee under cursor")
  same({ syntax.call_at(buffer, 0, 15) }, { "inner", "inner" }, "nested argument callee")
end
vim.api.nvim_set_current_buf(previous)
vim.api.nvim_buf_delete(buffer, { force = true })
