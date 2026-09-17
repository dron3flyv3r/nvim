-- Pins for plugins whose *released* version still calls a Neovim API that 0.12
-- deprecates. These are not cosmetic: every deprecation notice is printed at
-- startup, and because AstroNvim sets `cmdheight = 0`, printing anything forces
-- the message area open and pushes the statusline several rows off the bottom of
-- the screen. `:checkhealth vim.deprecated` lists whatever is left.
--
-- Each entry says what to watch for so it can be deleted again rather than
-- quietly outliving the problem.

---@type LazySpec
return {
  {
    -- `settings.set()` uses the table form of `vim.validate`, deprecated in 0.12
    -- and removed in 1.0. Upstream fixed it in 8e7806a, but that commit landed
    -- *after* the v2.6.0 tag and AstroNvim's snapshot asks for `^2` -- so the
    -- version range can only ever resolve to the broken release. Drop the pin
    -- once a tag newer than v2.6.0 exists.
    "jay-babu/mason-null-ls.nvim",
    optional = true,
    version = false,
    commit = "8e7806acaa87fae64f0bfde25bb4b87c18bd19b4",
  },
}
