-- Notebook runtime wiring. User-facing actions are registered with the shared
-- contextual action system; there is no separate notebook key vocabulary.
--
-- WHAT THIS IS FOR: the thing a fresh Python process is not good at. A
-- script run is a fresh process every time, so loading the dataset, building
-- the model and looking at one layer's activations means paying for the first
-- two on every iteration of the third. A kernel keeps the process alive
-- between runs -- load the data once, then poke at it all afternoon.
--
-- THE PIECES, and why each one is here:
--
--   * molten-nvim   -- owns the kernel. Sends a range of lines to it and draws
--                      whatever comes back (text, images, LaTeX, tracebacks)
--                      under the code as virtual lines.
--   * image.nvim    -- draws the pixels. Molten hands it PNGs; it works out how
--                      to get them onto the terminal.
--   * jupytext.nvim -- makes `.ipynb` editable. Converts to a `.py` with `# %%`
--                      cells on read and back on write, so the buffer is real
--                      Python and every language-server key still works.
--   * user.integrations.notebook -- cells, kernel selection, and saved
--                      outputs. See that file; the reasoning lives there.
--
-- NOT quarto-nvim / otter.nvim, which is the other common way to do this. Those
-- exist to get a language server into fenced code blocks inside a markdown
-- document. jupytext hands us a buffer that IS Python, so basedpyright, ruff
-- and `grn` already work on it and there is nothing to bridge.
--
-- FIRST RUN, on a machine where this has never worked:
--
--     :NotebookBootstrap     builds the host venv (uv), then restart
--     :NotebookHealth        says which of the pieces are missing
--     <Leader>ra             register the project's venv as a kernel
--     <Leader>rr             run the cell under the cursor
--
-- Kernel registration is per project and needs `ipykernel`: `uv add --dev
-- ipykernel`. Without it the only kernel on the machine is the host venv's,
-- which has none of your dependencies -- `import torch` would fail in a cell
-- while working fine as a normal Python module.

---@type LazySpec
return {
  {
    "3rd/image.nvim",
    lazy = true,

    -- image.nvim ships an `image.nvim-scm-1.rockspec`, and lazy.nvim acts on
    -- one when it finds it: it bootstraps `hererocks`, builds a private Lua
    -- 5.1 and luarocks inside `lazy-rocks/`, and compiles the `magick` FFI
    -- binding against ImageMagick's headers. That is a compiler toolchain and
    -- a second Lua on the critical path of `:Lazy sync`, for a binding that
    -- `processor = "magick_cli"` below does not use. `false` declines it --
    -- the pkg-derived `build = "rockspec"` only survives if the spec here
    -- leaves `build` unset.
    build = false,

    opts = function()
      return {
        -- Which graphics protocol the terminal on the other end speaks.
        -- The integration works it out; foot gets sixel, kitty gets kitty.
        backend = require("user.integrations.notebook").image_backend(),

        -- Shell out to the `magick` binary rather than link against
        -- ImageMagick through the `magick` luarock. The rock is the faster of
        -- the two and needs luarocks, which is not installed and which
        -- lazy.nvim would then have to bootstrap on every machine. The CLI is
        -- already in `/usr/bin` and the difference is one exec per image.
        processor = "magick_cli",

        -- Molten positions and sizes its own output images. The `markdown` and
        -- `neorg` integrations render images found *in the document*, on their
        -- own schedule, and the two fight over the same terminal placements --
        -- so nothing is enabled here and Molten is the only client.
        integrations = {},

        -- Molten's advice: let it decide, and clamp the height on its side
        -- with `molten_output_win_max_height` instead. Constraining images
        -- here as well means two independent scalers, and a figure that is
        -- mysteriously half the width you asked for.
        max_width_window_percentage = math.huge,
        max_height_window_percentage = math.huge,

        -- Blank the image when a float (completion menu, hover, the
        -- cheatsheet) is drawn over it. Terminal graphics live above the text
        -- grid and do not know about Neovim's windows, so without this a
        -- matplotlib figure shines straight through the popup on top of it.
        window_overlap_clear_enabled = true,
        window_overlap_clear_ft_ignore = { "cmp_menu", "cmp_docs", "blink-cmp-menu", "blink-cmp-documentation", "" },
      }
    end,
  },

  {
    "benlubas/molten-nvim",
    version = "^1",
    -- Molten is a Python REMOTE PLUGIN: the `:Molten*` commands do not exist
    -- until `:UpdateRemotePlugins` has written them into `rplugin.vim`, and it
    -- has to be re-run whenever the plugin updates.
    --
    -- NOT the bare `build = ":UpdateRemotePlugins"` from Molten's README.
    -- That command works by scanning `runtimepath` for `rplugin/python3/`
    -- directories -- and this plugin is deferred to a filetype, so at build
    -- time it is not on `runtimepath` and the scan finds nothing. It writes a
    -- manifest with no Molten in it and reports success, and the first
    -- the first contextual cell run says `:MoltenInit` is not an editor
    -- command. Load it first.
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

      -- THE COLAB LOOK: output as virtual lines under the cell, not in a
      -- floating window. It stays put while you keep editing, it scrolls with
      -- the buffer, and two cells' outputs are visible at once -- which a
      -- float, being one window, cannot do.
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
    -- Opens `.ipynb` as Python and writes it back as `.ipynb`. Needs the
    -- `jupytext` CLI on PATH: `uv tool install jupytext`.
    --
    -- Not lazy: it works by claiming `BufReadCmd` for `*.ipynb`, so if it is
    -- not loaded at the moment you open a notebook, Neovim shows you the raw
    -- JSON and the chance is gone. It only registers autocmds.
    "GCBallesteros/jupytext.nvim",
    lazy = false,
    opts = {
      -- The default, and the one that matches everything else here: `.py` with
      -- `# %%` cell markers. `markdown` style would give a markdown buffer,
      -- and then the Python in it would need otter.nvim to get a language
      -- server -- see the note at the top about not going that way.
      style = "hydrogen",
      output_extension = "auto",
    },
  },

}
