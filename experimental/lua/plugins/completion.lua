-- Temporary. Native `'autocomplete'` is the intended mechanism; it is off in
-- core/options.lua because on this nightly it applies LSP text edits mid-typing
-- and corrupts the buffer. See the completion section of AGENTS.md. Once that
-- is fixed upstream, delete this file and re-enable the option.
---@type LazySpec
return {
  "Saghen/blink.cmp",
  version = "1.*",
  event = "InsertEnter",
  ---@module 'blink.cmp'
  ---@type blink.cmp.Config
  opts = {
    -- j/k move through a list and l commits, matching the picker keys. <C-h>
    -- is deliberately absent: in insert mode it is backspace.
    keymap = {
      preset = "default",
      ["<C-j>"] = { "select_next", "fallback" },
      ["<C-k>"] = { "select_prev", "fallback" },
      ["<C-l>"] = { "accept", "fallback" },
      ["<C-y>"] = {},
    },
    appearance = { nerd_font_variant = "mono" },
    completion = {
      documentation = { auto_show = true, auto_show_delay_ms = 200 },
      menu = { draw = { treesitter = { "lsp" } } },
    },
    sources = { default = { "lsp", "path", "snippets", "buffer" } },
    signature = { enabled = true },
    fuzzy = { implementation = "prefer_rust_with_warning" },
  },
}
