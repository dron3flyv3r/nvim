-- `<Leader>j` -- notebooks. A Jupyter kernel, in this editor, in this file.
--
-- WHAT THIS IS FOR: the thing Colab is good at and `<Leader>rf` is not. A
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
--   * user.notebook -- cells, kernel selection, and the round-trip of saved
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
--     <Leader>jk             registers the project's venv as a kernel
--     <Leader>jj             run the cell under the cursor
--
-- `<Leader>jk` is per project and needs `ipykernel` in it: `uv add --dev
-- ipykernel`. Without it the only kernel on the machine is the host venv's,
-- which has none of your dependencies -- `import torch` would fail in a cell
-- while working fine under `<Leader>rf`.

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
        -- `user.notebook` works it out; foot gets sixel, kitty gets kitty.
        backend = require("user.notebook").image_backend(),

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
    -- `<Leader>jj` says `:MoltenInit` is not an editor command. Load it first.
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
      require("user.notebook").setup()

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

      -- `<Leader>je` opens the float on top for the times the virtual lines
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

  {
    "AstroNvim/astrocore",
    ---@param opts AstroCoreOpts
    opts = function(_, opts)
      local maps = assert(opts.mappings) -- guaranteed by `astrocore.lua`
      --- `<Leader>j` mappings all go through `user.notebook`, and requiring it
      --- inside the closure is what keeps it off the startup path.
      ---@param fn string
      ---@param arg any?
      local function nb(fn, arg)
        return function() require("user.notebook")[fn](arg) end
      end

      maps.n["<Leader>j"] = { desc = "󰠮 Notebook" }

      -- ── The two keys you actually wear out ────────────────────────────────
      -- Run this cell and stay put -- for iterating on the same block.
      maps.n["<Leader>jj"] = { nb("run_cell", false), desc = "Run cell" }
      -- Run it and move on. This is Colab's Shift+Enter, and how you walk a
      -- notebook from the top.
      maps.n["<Leader>jn"] = { nb("run_cell", true), desc = "Run cell and go to the next" }

      -- ── Running, the rest ─────────────────────────────────────────────────
      maps.n["<Leader>jl"] = { nb("run", "line"), desc = "Run this line" }
      maps.x["<Leader>jj"] = { nb("run", "visual"), desc = "Run selection" }
      maps.n["<Leader>jA"] = { nb "run_all", desc = "Run all cells" }
      -- Re-run the cell that produced the output you are standing on, without
      -- having to find it again.
      maps.n["<Leader>jr"] = { "<Cmd>MoltenReevaluateCell<CR>", desc = "Re-run this cell" }

      -- ── Cells ─────────────────────────────────────────────────────────────
      maps.n["<Leader>jc"] = { nb("insert_cell", true), desc = "New cell below" }
      maps.n["<Leader>ja"] = { nb("insert_cell", false), desc = "New cell above" }
      -- Pair-jumps, so `æj` / `øj` on the Danish layout -- see `danish-keys.lua`.
      maps.n["]j"] = { nb("goto_cell", 1), desc = "Next cell" }
      maps.n["[j"] = { nb("goto_cell", -1), desc = "Previous cell" }

      -- ── Output ────────────────────────────────────────────────────────────
      maps.n["<Leader>jo"] = { "<Cmd>MoltenShowOutput<CR>", desc = "Show output (float)" }
      -- `noautocmd` is not optional here, and Molten's docs say so: entering
      -- the output window fires the autocmds that Molten itself listens to for
      -- "the cursor left the cell", and it closes the window under you.
      maps.n["<Leader>je"] = { "<Cmd>noautocmd MoltenEnterOutput<CR>", desc = "Enter output (scroll, select)" }
      maps.n["<Leader>jh"] = { "<Cmd>MoltenHideOutput<CR>", desc = "Hide the output float" }
      -- Hand the image off to the system viewer. Worth having in foot, where
      -- the inline sixel render is the slow, low-fidelity one -- this is how
      -- you look at a figure properly without saving it first.
      maps.n["<Leader>jp"] = { "<Cmd>MoltenImagePopup<CR>", desc = "Open this output's image in a viewer" }
      -- Plotly and friends emit HTML, which no terminal can draw.
      maps.n["<Leader>jb"] = { "<Cmd>MoltenOpenInBrowser<CR>", desc = "Open HTML output in the browser" }
      -- Removes the cell AND its output. Molten tracks cells by extmark, so
      -- deleting the lines alone leaves the output orphaned on screen.
      maps.n["<Leader>jd"] = { "<Cmd>MoltenDelete<CR>", desc = "Delete this cell's output" }

      -- ── Kernel ────────────────────────────────────────────────────────────
      -- `<Leader>jj` starts a kernel by itself; these are for taking over.
      maps.n["<Leader>ji"] = { "<Cmd>MoltenInit<CR>", desc = "Start a kernel (pick one)" }
      maps.n["<Leader>jk"] = { nb "register_kernel", desc = "Register this project's venv as a kernel" }
      maps.n["<Leader>jx"] = { "<Cmd>MoltenInterrupt<CR>", desc = "Interrupt (KeyboardInterrupt)" }
      -- The one for when the state is wrong rather than the code. `!` also
      -- clears the outputs, so you are not reading results from before.
      maps.n["<Leader>jZ"] = { "<Cmd>MoltenRestart!<CR>", desc = "Restart the kernel (clears outputs)" }
      maps.n["<Leader>jq"] = { "<Cmd>MoltenDeinit<CR>", desc = "Shut the kernel down" }

      -- ── Notebook files ────────────────────────────────────────────────────
      -- Both happen automatically for `.ipynb` (see `user.notebook`); these are
      -- for doing it by hand, e.g. exporting a `.py` you have been working in.
      maps.n["<Leader>jI"] = { "<Cmd>MoltenImportOutput<CR>", desc = "Import outputs from the .ipynb" }
      maps.n["<Leader>jE"] = { "<Cmd>MoltenExportOutput!<CR>", desc = "Export outputs to the .ipynb" }
      maps.n["<Leader>j?"] = { "<Cmd>NotebookHealth<CR>", desc = "Check the notebook setup" }
    end,
  },
}
