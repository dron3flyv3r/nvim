-- AstroUI: colorscheme, highlights and icons.
-- Configuration documentation: `:h astroui`
---@type LazySpec
return {
  "AstroNvim/astroui",
  ---@type AstroUIOpts
  opts = {
    -- From `astrocommunity.colorscheme.onedarkpro-nvim` (see `community.lua`).
    colorscheme = "onedark",

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
