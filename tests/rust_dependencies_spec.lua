local dependencies = require "user.languages.rust.dependencies"

local function same(actual, expected, label)
  assert(
    vim.deep_equal(actual, expected),
    ("%s: expected %s, got %s"):format(label, vim.inspect(expected), vim.inspect(actual))
  )
end

same(
  dependencies.parse_search [[
rand = "0.10.2" # Random number generators
ratatui = "0.30.0" # Terminal UI library
... and 20 crates more (use --limit N to see more)
]],
  {
    { name = "rand", version = "0.10.2", description = "Random number generators" },
    { name = "ratatui", version = "0.30.0", description = "Terminal UI library" },
  },
  "cargo search parsing"
)

local info = dependencies.parse_info [[
rand #random #rng
Random number generators and other randomness functionality.
version: 0.10.2
license: MIT OR Apache-2.0
rust-version: 1.85
documentation: https://docs.rs/rand
features:
 +default    = [std, thread_rng]
  serde      = [dep:serde]
  unbiased   = []
dependencies:
 +rand_core@0.10.0
]]
same(info.version, "0.10.2", "cargo info version")
same(info.rust_version, "1.85", "cargo info rust-version")
same(info.features, {
  { name = "default", members = { "std", "thread_rng" }, default = true },
  { name = "serde", members = { "dep:serde" }, default = false },
  { name = "unbiased", members = {}, default = false },
}, "cargo info features")

same(
  dependencies.add_args {
    name = "tokio",
    manifest = "/tmp/demo/Cargo.toml",
    kind = "dev",
    features = { "macros", "rt-multi-thread" },
    default_features = false,
  },
  {
    "add",
    "tokio",
    "--manifest-path",
    "/tmp/demo/Cargo.toml",
    "--dev",
    "--no-default-features",
    "--features",
    "macros,rt-multi-thread",
  },
  "cargo add arguments"
)

same(
  dependencies.missing_name(
    { code = "E0433", message = "use of unresolved module or unlinked crate `rand`" },
    "use rand::Rng;"
  ),
  "rand",
  "missing external crate"
)
same(
  dependencies.missing_name(
    { code = "E0433", message = "use of unresolved module or unlinked crate `std`" },
    "use std::io;"
  ),
  nil,
  "standard library exclusion"
)

local previous = vim.api.nvim_get_current_buf()
local buffer = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buffer)
vim.cmd "noautocmd setlocal filetype=rust"
vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "use rand::Rng;" })
vim.api.nvim_win_set_cursor(0, { 1, 5 })
local namespace = vim.api.nvim_create_namespace "rust_dependencies_spec"
vim.diagnostic.set(namespace, buffer, {
  {
    lnum = 0,
    col = 4,
    end_lnum = 0,
    end_col = 8,
    severity = vim.diagnostic.severity.ERROR,
    code = "E0433",
    message = "use of unresolved module or unlinked crate `rand`",
  },
})
local old_select = vim.ui.select
vim.ui.select = function(items, opts, callback)
  same(items, { "Add Cargo dependency `rand`", "Show other code actions" }, "quick-fix choices")
  same(opts.prompt, "Unresolved Rust crate", "quick-fix prompt")
  callback(nil)
end
assert(dependencies.offer_quick_fix(function() error "unexpected LSP fallback" end), "quick-fix should be offered")
vim.api.nvim_feedkeys("v", "nx", false)
assert(not dependencies.offer_quick_fix(function() end), "visual gra should remain an ordinary range code action")
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
vim.ui.select = old_select
vim.diagnostic.reset(namespace, buffer)
vim.api.nvim_set_current_buf(previous)
vim.api.nvim_buf_delete(buffer, { force = true })
