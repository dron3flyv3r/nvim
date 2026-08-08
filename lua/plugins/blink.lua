-- Completion tweaks for `blink.cmp` (AstroNvim v5's completion engine).
--
-- `signature.enabled` defaults to false upstream, so AstroNvim only styles the
-- window without ever showing it. Turning it on gives the VS Code style hint:
-- a float listing the function's parameters and their types, with the parameter
-- you're currently typing highlighted. It updates as you type commas.
--
-- Note AstroLSP has its own `features.signature_help`; AstroNvim automatically
-- disables that one when blink's is enabled, so there's no double popup.
---@type LazySpec
return {
  "Saghen/blink.cmp",
  opts = {
    signature = {
      enabled = true,
      trigger = {
        enabled = true,
        show_on_insert_on_trigger_character = true, -- pop up as soon as you type `(`
      },
      window = {
        show_documentation = false, -- keep it to the signature line, not the full docstring
      },
    },
  },
}
