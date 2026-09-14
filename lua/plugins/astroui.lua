-- AstroUI: colorscheme, highlights and icons.
-- Configuration documentation: `:h astroui`
---@type LazySpec
return {
  "AstroNvim/astroui",
  ---@type AstroUIOpts
  opts = {
    -- From `astrocommunity.colorscheme.onedarkpro-nvim` (see `community.lua`).
    colorscheme = "onedark",

    -- `<Leader>gp` -- gitsigns' inline hunk preview. onedark defines the
    -- line-level preview groups but not the `VirtLn` family, so gitsigns falls
    -- back through `DeleteVirtLnInLine -> DeleteLnInline -> DeleteInline ->
    -- DiffDelete` and paints the word-level marks in exactly the colour of the
    -- line they sit on. Measured against the old text's own background that is
    -- dE 0.0 -- not dim, the same colour -- so the one thing the preview is for,
    -- saying *which words* in the line changed, never showed at all. The old
    -- line numbers in the float landed on the same colour for the same reason.
    --
    -- Only the groups gitsigns uses for previews are set here. `DiffAdd` and
    -- friends are deliberately left alone: `user/diff_hud.lua` derives its
    -- BEFORE/YOURS/AFTER bars from them, so restyling those would repaint the
    -- whole Diffview review as a side effect of fixing this preview.
    highlights = {
      onedark = {
        -- Line level. Enough to read as changed, not enough to drown the text.
        GitSignsAddPreview = { bg = "#2d3f31" },
        GitSignsDeletePreview = { bg = "#43303a" },
        GitSignsDeleteVirtLn = { bg = "#43303a" },

        -- Word level, drawn on top of the above, so these are picked to stand
        -- against *that* background rather than against `Normal`. The explicit
        -- foreground is the point: a background strong enough to see (dE 22-32)
        -- drops unstyled code to ~3:1, and these few characters are exactly the
        -- ones worth reading, so they get a bright fg instead of syntax colour.
        GitSignsAddInline = { bg = "#3d6b4a", fg = "#e8ecf4" },
        GitSignsChangeInline = { bg = "#4a5f7d", fg = "#e8ecf4" },
        GitSignsDeleteInline = { bg = "#7a3a46", fg = "#e8ecf4" },
        GitSignsDeleteVirtLnInLine = { bg = "#7a3a46", fg = "#e8ecf4" },

        -- The old file's line numbers down the side of the float.
        GitSignsVirtLnum = { bg = "#43303a", fg = "#9aa3b2" },
      },
    },

    -- The braille spinner the statusline uses while a server is starting up.
    icons = {
      LSPLoading1 = "⠋",
      LSPLoading2 = "⠙",
      LSPLoading3 = "⠹",
      LSPLoading4 = "⠸",
      LSPLoading5 = "⠼",
      LSPLoading6 = "⠴",
      LSPLoading7 = "⠦",
      LSPLoading8 = "⠧",
      LSPLoading9 = "⠇",
      LSPLoading10 = "⠏",
    },
  },
}
