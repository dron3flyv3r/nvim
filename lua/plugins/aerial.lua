-- AstroNvim's `lazy_snapshot` pins aerial.nvim to `^2.2`, but Neovim 0.12 removed
-- the `{ all = false }` option from `Query:iter_matches()`, so aerial 2.x/3.x get a
-- table of nodes where they expect a single TSNode and crash in
-- `range_from_nodes` with "attempt to call method 'start' (a nil value)".
-- aerial 4.x fixes this (and requires nvim >= 0.12, which we have).
---@type LazySpec
return {
  { "stevearc/aerial.nvim", version = "^4" },
}
