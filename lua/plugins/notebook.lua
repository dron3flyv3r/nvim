-- Molten, image.nvim, and jupytext wiring. User actions stay in the contextual
-- action system; setup and design notes live in `docs/decisions/notebooks.md`.

---@type LazySpec
return {
  {
    "3rd/image.nvim",
    lazy = true,

    build = false,

    opts = function()
      return {
        -- Which graphics protocol the terminal on the other end speaks.
        -- The integration works it out; foot gets sixel, kitty gets kitty.
        backend = require("user.integrations.notebook").image_backend(),

        processor = "magick_cli",

        integrations = {},

        max_width_window_percentage = math.huge,
        max_height_window_percentage = math.huge,

        window_overlap_clear_enabled = true,
        window_overlap_clear_ft_ignore = { "cmp_menu", "cmp_docs", "blink-cmp-menu", "blink-cmp-documentation", "" },
      }
    end,
  },

  {
    "benlubas/molten-nvim",
    version = "^1",
    build = function()
      require("lazy").load { plugins = { "molten-nvim" } }
      vim.cmd "UpdateRemotePlugins"
    end,
    ft = { "python", "markdown" },
    dependencies = { "3rd/image.nvim" },

    -- `init` runs at startup even though the plugin itself is deferred, which
    -- is what these need: `python3_host_prog` must be set before the host
    -- starts, and the `.ipynb` autocmds must exist before you open one.
    init = function()
      require("user.integrations.notebook").setup()

      vim.g.molten_image_provider = "image.nvim"

      vim.g.molten_virt_text_output = true
      vim.g.molten_auto_open_output = false -- the float would cover the virt lines
      vim.g.molten_virt_lines_off_by_1 = true -- percent format: sit above the next `# %%`
      vim.g.molten_wrap_output = true
      vim.g.molten_output_win_max_height = 20 -- a stack trace should not eat the screen

      -- The context menu opens the float on top when virtual lines
      -- are not enough -- a long traceback to scroll, or an image to look at
      -- properly. Entering it is the only way to select text out of output.
      vim.g.molten_enter_output_behavior = "open_and_enter"
      vim.g.molten_output_crop_border = true
      vim.g.molten_output_show_more = true

      -- NOT `molten_copy_output`. It sounds like a keybinding and is not one:
      -- it copies the output of EVERY evaluation to the system clipboard as it
      -- arrives, so a run of cells quietly destroys whatever you had yanked.
    end,
  },

  {
    "GCBallesteros/jupytext.nvim",
    lazy = false,
    opts = {
      style = "hydrogen",
      output_extension = "auto",
    },
  },
}
