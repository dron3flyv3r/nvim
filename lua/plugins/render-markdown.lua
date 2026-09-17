-- `open_floating_preview` gives the hover window `filetype=markdown` on a
-- `nofile` buffer, which is exactly the shape render-markdown's own
-- `buftype.nofile` override exists for -- so the docs `K` shows get real
-- headings, bullets and table borders without any hover-specific wiring.
---@type LazySpec
return {
  {
    "MeanderingProgrammer/render-markdown.nvim",
    optional = true,
    opts = {
      overrides = {
        buftype = {
          nofile = {
            -- Un-rendering the line under the cursor is right while editing and
            -- wrong while reading: in a focused hover the cursor is only there
            -- to scroll, and raw `###` flickering under it is noise.
            anti_conceal = { enabled = false },
            sign = { enabled = false },
          },
        },
      },
    },
  },
}
