-- Cells and kernels behind the shared contextual action menu.
--
-- The Colab loop is: put the cursor in a block of code, press one key, see the
-- output -- text, a DataFrame, a matplotlib figure -- appear underneath it,
-- with the variables still alive for the next block. Molten provides the
-- kernel and the output rendering; this file provides the *cell*, which Molten
-- deliberately has no opinion about.
--
-- A CELL is the run of lines between two `# %%` markers. That is the "percent
-- format": what jupytext writes, what VS Code's interactive window reads, and
-- what you get from a Colab notebook downloaded as `.py`. A file with no
-- markers at all is one cell; the context menu can insert markers to carve it
-- into smaller cells.
--
-- WHY THE FILE ON DISK IS STILL A `.py`: jupytext.nvim converts `.ipynb` on
-- read and back on write, so what sits in the buffer is ordinary Python. That
-- is the whole reason this arrangement beats a browser -- basedpyright types
-- it, ruff formats it, `grn` renames across it, and it diffs in git. A real
-- `.ipynb` buffer would be JSON, and none of that would work.

local M = {}

--- A cell boundary. Matches `# %%`, `#%%` and `# %% [markdown]`.
--- (`%%` is an escaped `%` in a Lua pattern, so `%%%%` is a literal `%%`.)
local CELL = "^%s*#%s*%%%%"

--- A prose cell: `# %% [markdown]`. Its body is a block of `#` comments that
--- jupytext turns back into a markdown cell.
---
--- These are not sent to the kernel. Doing so is harmless in Python -- it is
--- all comments -- but it makes Molten believe the notebook has a code cell
--- where the notebook says markdown, and `MoltenExportOutput` then refuses to
--- save ANY outputs ("No cell matching cell at line: N ... Bailing"), so one
--- text cell silently costs you every plot in the file.
local CELL_PROSE = "^%s*#%s*%%%%%s*%[markdown%]"

--- The line inserted by the contextual cell actions.
local MARKER = "# %%"

--- Python packages the Molten host needs, as `{ install name, import name }`.
---
--- `pynvim` and `jupyter_client` are required; the rest each unlock one output
--- type, and Molten degrades quietly without them -- which is exactly the kind
--- of quiet you do not want when a plot fails to appear, so they all go in.
---
--- Both names, because they are not always the same one: `pip install pillow`
--- gives you `import PIL`. Deriving either from the other is how a health
--- check ends up reporting a package missing that is sitting right there.
local HOST_PACKAGES = {
  { "pynvim", "pynvim" }, -- the remote-plugin bridge; without it Molten does not exist
  { "jupyter_client", "jupyter_client" }, -- talks to the kernel
  { "ipykernel", "ipykernel" }, -- provides the fallback `python3` kernel
  { "nbformat", "nbformat" }, -- MoltenImportOutput / MoltenExportOutput
  { "pillow", "PIL" }, -- image output
  { "cairosvg", "cairosvg" }, -- SVG output (seaborn, plotnine), with transparency
  { "pnglatex", "pnglatex" }, -- LaTeX output (sympy)
}

---@param index 1|2 1 = install names, 2 = import names
---@return string[]
local function host_packages(index)
  return vim.tbl_map(function(p) return p[index] end, HOST_PACKAGES)
end

--- Where the Molten host venv lives. Separate from every project venv on
--- purpose: this one belongs to the editor, and adding `pynvim` to a course
--- project's `pyproject.toml` to make the editor work would be backwards.
---@return string
function M.host_venv()
  return vim.fs.joinpath(vim.fn.stdpath "data" --[[@as string]], "molten-venv")
end

---@return string
function M.host_python() return vim.fs.joinpath(M.host_venv(), "bin", "python") end

--- Molten is lazy-loaded on filetype, so its commands may not exist yet.
---@return boolean ok
local function load_molten()
  if vim.fn.exists ":MoltenInit" == 2 then return true end
  pcall(function() require("lazy").load { plugins = { "molten-nvim" } } end)
  if vim.fn.exists ":MoltenInit" == 2 then return true end
  vim.notify(
    "Molten is not available -- run :NotebookBootstrap, then restart",
    vim.log.levels.ERROR,
    { title = "Notebook" }
  )
  return false
end

--- Is a kernel attached to this buffer?
---
--- NOT `molten.status.initialized()`, which the Molten docs use for exactly
--- this and which does not mean it. That one returns the string "Molten" as
--- soon as the *plugin* has woken up, whether or not a kernel was ever
--- started -- so it is true in every Python buffer you open, and building on
--- it means skipping the init and then handing lines to a kernel that is not
--- there. `MoltenRunningKernels(true)` is the buffer-local list, which is the
--- actual question.
---@return boolean
local function initialized()
  local ok, kernels = pcall(vim.fn.MoltenRunningKernels, true)
  return ok and type(kernels) == "table" and not vim.tbl_isempty(kernels)
end

--- Where Jupyter writes a kernel's connection file.
---
--- Reimplements `jupyter_core.paths.jupyter_runtime_dir` for Linux, which is
--- `$JUPYTER_RUNTIME_DIR`, else the data dir plus `runtime/`. Asking Python
--- for it would be a subprocess on the startup path to learn something that
--- has not changed in a decade.
---@return string
local function jupyter_runtime_dir()
  if vim.env.JUPYTER_RUNTIME_DIR then return vim.env.JUPYTER_RUNTIME_DIR end
  local data = vim.env.JUPYTER_DATA_DIR
    or vim.fs.joinpath(vim.env.XDG_DATA_HOME or vim.fs.joinpath(vim.env.HOME, ".local", "share"), "jupyter")
  return vim.fs.joinpath(data, "runtime")
end

-- ── Cells ───────────────────────────────────────────────────────────────────

--- 1-indexed line numbers of every `# %%` marker in the buffer.
---@return integer[]
function M.cell_starts()
  local starts = {}
  for i, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
    if line:match(CELL) then starts[#starts + 1] = i end
  end
  return starts
end

--- The cell containing `lnum`, as an inclusive 1-indexed line range.
---
--- The marker line is part of the range rather than skipped: it is a comment,
--- so sending it costs nothing, and keeping it in means Molten anchors the
--- output extmark to the cell you can see rather than to the line after it.
---@param lnum integer? defaults to the cursor line
---@return integer first, integer last
function M.cell_bounds(lnum)
  lnum = lnum or vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)

  local first = 1
  for i = lnum, 1, -1 do
    if lines[i] and lines[i]:match(CELL) then
      first = i
      break
    end
  end

  local last = #lines
  for i = lnum + 1, #lines do
    if lines[i]:match(CELL) then
      last = i - 1
      break
    end
  end

  return first, last
end

--- Jump to the next (`dir > 0`) or previous cell marker.
---
--- From the middle of a cell, "previous" means this cell's own marker -- the
--- same way `{` goes to the top of the paragraph you are in before it goes to
--- the one before it.
---@param dir 1|-1
function M.goto_cell(dir)
  local starts = M.cell_starts()
  if vim.tbl_isempty(starts) then
    vim.notify("No `# %%` cells in this file -- <Leader>ra can add one", vim.log.levels.INFO, { title = "Notebook" })
    return
  end

  local cur = vim.api.nvim_win_get_cursor(0)[1]
  local target
  if dir > 0 then
    for _, s in ipairs(starts) do
      if s > cur then
        target = s
        break
      end
    end
  else
    local first = M.cell_bounds(cur)
    if first < cur then
      target = first
    else
      for i = #starts, 1, -1 do
        if starts[i] < cur then
          target = starts[i]
          break
        end
      end
    end
  end
  if not target then return end

  vim.cmd "normal! m'" -- leave a jumplist entry, so `<C-o>` / `<BS>` come back
  vim.api.nvim_win_set_cursor(0, { target, 0 })
end

--- Open a new empty cell below (or above) the one the cursor is in, and start
--- typing in it.
---@param below boolean
function M.insert_cell(below)
  local first, last = M.cell_bounds()
  local at = below and last or first - 1
  vim.api.nvim_buf_set_lines(0, at, at, false, { "", MARKER, "" })
  vim.api.nvim_win_set_cursor(0, { at + 3, 0 })
  vim.cmd.startinsert()
end

-- ── Kernels ─────────────────────────────────────────────────────────────────

--- Jupyter kernel names this machine knows about.
---@return string[]
local function available_kernels()
  local ok, kernels = pcall(vim.fn.MoltenAvailableKernels)
  if not ok or type(kernels) ~= "table" then return {} end
  return kernels
end

--- Resolve the current buffer with `user.languages.python.target`.
---
--- That module answers "how do I run this Python file", and it decides whether
--- a buffer is Python by looking at the extension -- rightly, since it feeds
--- `python -m` on a notebook is meaningless. But a `.ipynb`
--- open here IS Python, in the same project, wanting the same interpreter, so
--- it is handed over under the name jupytext gives it on disk anyway.
---@return user.PythonTarget?
local function target_for_buffer()
  local file = vim.api.nvim_buf_get_name(0)
  return require("user.languages.python.target").resolve((file:gsub("%.ipynb$", ".py")))
end

--- The kernel name this project registers itself under: its root directory,
--- with anything Jupyter would object to in a directory name replaced.
---@return string? name, user.PythonTarget? target
function M.project_kernel()
  local target = target_for_buffer()
  if not target then return nil, nil end
  return (vim.fs.basename(target.root):gsub("[^%w_%-%.]", "-")), target
end

--- Run `fn` with a kernel attached to this buffer, starting one if needed.
---
--- The kernel is picked, not prompted for, whenever the project has registered
--- one (see `M.register_kernel`) -- that is what makes the first `<Leader>rr`
--- of the day a single keypress instead of a keypress and a menu.
---
--- Molten's own bare `:MoltenInit` also prompts, but it does so through
--- `vim.ui.select` *after* returning, so there is no way to run anything once
--- the choice is made. Hence the picker here rather than deferring to it.
---@param fn fun()
function M.with_kernel(fn)
  if not load_molten() then return end
  if initialized() then return fn() end

  local kernels = available_kernels()
  if vim.tbl_isempty(kernels) then
    vim.notify(
      "No Jupyter kernels installed -- <Leader>ra can register this project's venv",
      vim.log.levels.WARN,
      { title = "Notebook" }
    )
    return
  end

  -- A kernel is a separate OS process. `MoltenInit` returns as soon as it has
  -- been spawned and the buffer registered -- NOT when it can run anything --
  -- and code sent in the window between the two is accepted, executed, and
  -- has its output dropped on the floor: the cell sits at `Out[...]: * On
  -- Hold` forever while the next cell you run inherits its result. So the
  -- very first contextual cell run waits for Molten to say it is ready.
  local function start(name)
    vim.api.nvim_create_autocmd("User", {
      pattern = "MoltenKernelReady",
      once = true,
      desc = "Run the cell that started this kernel",
      callback = fn,
    })
    vim.cmd("MoltenInit " .. name)
  end

  local want = M.project_kernel()
  if want and vim.tbl_contains(kernels, want) then return start(want) end
  if #kernels == 1 then return start(kernels[1]) end

  vim.ui.select(kernels, { prompt = "Jupyter kernel" }, function(choice)
    if choice then start(choice) end
  end)
end

--- Register this project's interpreter as a Jupyter kernel named after the
--- project, so `<Leader>rr` can find it without asking.
---
--- WHY THIS IS NEEDED AT ALL: the kernel is a separate process, and Jupyter
--- starts it from a *kernelspec* -- a `kernel.json` under
--- `~/.local/share/jupyter/kernels/` naming an interpreter. Nothing writes one
--- for a uv project, so out of the box the only kernel on the machine is the
--- host venv's own, which has `jupyter_client` in it and none of your
--- dependencies. `import torch` in a cell would fail while `python -m` on the
--- same file worked, which is a maddening thing to debug.
---
--- `ipykernel install` records `sys.executable`, so the spec ends up pointing
--- at `<root>/.venv/bin/python` -- a stable path -- even though it is invoked
--- here through `uv run`.
function M.register_kernel()
  local name, target = M.project_kernel()
  if not name or not target then
    vim.notify("Not a Python file", vim.log.levels.WARN, { title = "Notebook" })
    return
  end

  local cmd = vim.list_extend(vim.list_slice(target.py), {
    "-m",
    "ipykernel",
    "install",
    "--user",
    "--name",
    name,
    "--display-name",
    ("%s (%s)"):format(name, target.label),
  })

  vim.notify(("Registering kernel `%s`..."):format(name), vim.log.levels.INFO, { title = "Notebook" })
  vim.system(cmd, { cwd = target.root, text = true }, function(out)
    vim.schedule(function()
      if out.code == 0 then
        vim.notify(
          ("Kernel `%s` registered -- <Leader>rr will use it from now on"):format(name),
          vim.log.levels.INFO,
          { title = "Notebook" }
        )
        return
      end
      -- Far and away the most common failure, and the error text alone
      -- ("No module named ipykernel") does not say what to do about it.
      local hint = (out.stderr or ""):match "No module named ipykernel"
          and "\n\nAdd it to the project first:  uv add --dev ipykernel"
        or ""
      vim.notify(
        ("Could not register kernel:\n%s%s"):format(vim.trim(out.stderr or out.stdout or ""), hint),
        vim.log.levels.ERROR,
        { title = "Notebook" }
      )
    end)
  end)
end

-- ── Running ─────────────────────────────────────────────────────────────────

--- Send an inclusive 1-indexed line range to the kernel.
---
--- `MoltenEvaluateRange` is one of the handful of things Molten exposes as a
--- *function* rather than a command (`:MoltenEvaluateRange 3 6` is "Not an
--- editor command"), because a command can only take strings and this needs
--- real numbers. Called with two arguments it spans whole lines: the end
--- column defaults to 0, which Molten turns into -1, i.e. end of line.
---@param first integer
---@param last integer
local function evaluate(first, last) vim.fn.MoltenEvaluateRange(first, last) end

--- Is the cell starting at `lnum` prose rather than code?
---@param lnum integer
---@return boolean
local function is_prose(lnum)
  local line = vim.api.nvim_buf_get_lines(0, lnum - 1, lnum, false)[1]
  return line ~= nil and line:match(CELL_PROSE) ~= nil
end

--- Evaluate the cell under the cursor.
---@param advance boolean move to the next cell afterwards (Colab's Shift+Enter)
function M.run_cell(advance)
  local first, last = M.cell_bounds()
  -- Shift+Enter on a text cell in a notebook moves on rather than complaining,
  -- and so does this.
  if is_prose(first) then
    if advance then M.goto_cell(1) end
    return
  end
  M.with_kernel(function()
    evaluate(first, last)
    if advance then M.goto_cell(1) end
  end)
end

--- Evaluate every cell, top to bottom. Molten queues them, so they run in
--- order against the one kernel rather than all at once.
function M.run_all()
  local starts = M.cell_starts()
  local total = vim.api.nvim_buf_line_count(0)
  M.with_kernel(function()
    if vim.tbl_isempty(starts) then
      evaluate(1, total)
      return
    end
    -- A preamble above the first marker -- imports, usually -- is its own cell.
    if starts[1] > 1 then evaluate(1, starts[1] - 1) end
    for i, s in ipairs(starts) do
      if not is_prose(s) then evaluate(s, (starts[i + 1] or total + 1) - 1) end
    end
  end)
end

--- Evaluate the current line, or the visual selection.
---@param mode "line"|"visual"
function M.run(mode)
  M.with_kernel(function() vim.cmd(mode == "visual" and "MoltenEvaluateVisual" or "MoltenEvaluateLine") end)
end

-- ── Bootstrap ───────────────────────────────────────────────────────────────

--- Build the host venv from nothing. Called by `:NotebookBootstrap`, and what
--- makes this config work on a machine it has never run on.
function M.bootstrap()
  if vim.fn.executable "uv" ~= 1 then
    vim.notify("uv is not installed", vim.log.levels.ERROR, { title = "Notebook" })
    return
  end

  local venv = M.host_venv()
  vim.notify("Building the Molten host venv...", vim.log.levels.INFO, { title = "Notebook" })

  vim.system({ "uv", "venv", venv }, { text = true }, function(mk)
    if mk.code ~= 0 then
      vim.schedule(
        function()
          vim.notify("uv venv failed:\n" .. vim.trim(mk.stderr or ""), vim.log.levels.ERROR, { title = "Notebook" })
        end
      )
      return
    end

    local install = vim.list_extend({ "uv", "pip", "install", "--python", M.host_python() }, host_packages(1))
    vim.system(install, { text = true }, function(pip)
      vim.schedule(function()
        if pip.code ~= 0 then
          vim.notify(
            "uv pip install failed:\n" .. vim.trim(pip.stderr or ""),
            vim.log.levels.ERROR,
            { title = "Notebook" }
          )
          return
        end
        -- The manifest that maps `:Molten*` to the Python host is generated
        -- from the interpreter that is current *now*, so it has to be rebuilt
        -- after the venv exists -- not before.
        vim.g.python3_host_prog = M.host_python()
        vim.cmd "UpdateRemotePlugins"
        vim.notify(
          "Molten host ready. Restart Neovim, then use <Leader>ra in a project.",
          vim.log.levels.INFO,
          { title = "Notebook" }
        )
      end)
    end)
  end)
end

--- Report what is and is not in place. `:checkhealth` covers Molten itself;
--- this covers the parts of the arrangement that are ours.
function M.health()
  local lines = {}
  local function row(ok, text) lines[#lines + 1] = ("%s %s"):format(ok and "✓" or "✗", text) end

  local py = M.host_python()
  local have_venv = vim.uv.fs_stat(py) ~= nil
  row(have_venv, "host venv: " .. py)
  if have_venv then
    local out = vim.system({ py, "-c", "import " .. table.concat(host_packages(2), ", ") }, { text = true }):wait()
    row(out.code == 0, out.code == 0 and "host packages" or ("host packages: " .. vim.trim(out.stderr or "")))
  end

  row(vim.fn.exists ":MoltenInit" == 2, "molten commands (:MoltenInit)")
  row(vim.uv.fs_stat(jupyter_runtime_dir()) ~= nil, "jupyter runtime dir: " .. jupyter_runtime_dir())
  row(vim.fn.executable "jupytext" == 1, "jupytext CLI (.ipynb read/write)")
  row(vim.fn.executable "magick" == 1, "imagemagick (image.nvim processor)")

  local backend = M.image_backend()
  row(true, ("image backend: %s%s"):format(backend, backend == "sixel" and "  (sixel is slower than kitty)" or ""))

  local kernels = available_kernels()
  row(not vim.tbl_isempty(kernels), "kernels: " .. (vim.tbl_isempty(kernels) and "none" or table.concat(kernels, ", ")))

  local want = M.project_kernel()
  if want then row(vim.tbl_contains(kernels, want), ("this project's kernel `%s`"):format(want)) end

  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "Notebook health" })
end

-- ── Terminal capabilities ───────────────────────────────────────────────────

--- Which image.nvim backend this terminal can actually take.
---
--- The two protocols are not interchangeable and nothing negotiates between
--- them, so this has to be decided up front:
---
---   * KITTY GRAPHICS -- kitty, ghostty, WezTerm. Fast, cached, clipped
---     properly by Neovim's windows. What you want.
---   * SIXEL -- foot, xterm. Every frame is re-transmitted as text, so a big
---     matplotlib figure is visibly slower to appear and flickers on scroll.
---     It is the only thing foot speaks (`foot --version` reports no graphics
---     protocol beyond it), and foot is the terminal here.
---
--- Detection is by environment variable rather than `$TERM`, because
--- `~/.config/foot/foot.ini` sets `term=xterm-256color` -- so `$TERM` says
--- nothing about which of the two is on the other end.
---@return "kitty"|"sixel"
function M.image_backend()
  if vim.env.KITTY_WINDOW_ID or vim.env.TERM == "xterm-kitty" then return "kitty" end
  if vim.env.GHOSTTY_RESOURCES_DIR or vim.env.GHOSTTY_BIN_DIR then return "kitty" end
  if vim.env.WEZTERM_PANE then return "kitty" end
  return "sixel"
end

-- ── Compatibility ───────────────────────────────────────────────────────────

--- Replace Molten's `remove_comments`, which throws on Neovim 0.12.
---
--- THE BREAKAGE: exporting outputs into a `.ipynb` has to work out which
--- notebook cell each Molten cell corresponds to, and it does that by
--- comparing their code with the comments stripped -- so `# %%` markers and a
--- reworded comment do not count as a different cell. The stripping uses a
--- treesitter query with an `#offset!` directive and then reads
--- `metadata[1].range`, which on 0.12 is nil:
---
---     remove_comments.lua:19: attempt to index local 'region' (a nil value)
---
--- Same root cause as `user.compat.treesitter_directives` -- a capture may
--- match several nodes, so directive metadata is keyed and shaped differently
--- than the code here assumes. The error surfaces from deep inside a Python
--- remote call on every `:w` of a notebook, and the outputs are silently not
--- saved.
---
--- The directive was never load-bearing: its offsets are computed and then
--- ignored, since only the comment's start position is read. So this asks the
--- nodes for their own ranges and skips the directive entirely.
---
--- Molten re-runs `require('remove_comments')` before each comparison
--- (`ipynb.py`), so seeding `package.loaded` is enough -- there is no moment
--- where the original gets used first.
local function patch_comment_stripping()
  package.loaded["remove_comments"] = {
    ---@param str string
    ---@param lang string
    ---@return string
    remove_comments = function(str, lang)
      local ok, parser = pcall(vim.treesitter.get_string_parser, str, lang)
      if not ok then return str end -- no parser for this language: nothing to strip
      local root = parser:parse()[1]:root()
      local query = vim.treesitter.query.parse(lang, "((comment) @c)")
      local lines = vim.split(str, "\n")
      for _, node in query:iter_captures(root, str) do
        local row, col = node:range()
        lines[row + 1] = string.sub(lines[row + 1], 1, col)
      end
      -- Blank lines go too, so that whitespace differences between the
      -- notebook's copy and the buffer's do not read as a different cell.
      return vim.fn.join(vim.tbl_filter(function(line) return line ~= "" end, lines), "\n")
    end,
  }
end

-- ── Wiring ──────────────────────────────────────────────────────────────────

--- Point Neovim's Python host at the Molten venv, register the commands, and
--- set up the `.ipynb` output round-trip. Called from the Molten spec's `init`,
--- so it runs at startup even though Molten itself is lazy.
function M.setup()
  -- Only if it is actually there: a broken `python3_host_prog` breaks every
  -- Python remote plugin, and pointing at a venv that does not exist yet is
  -- worse than leaving the default alone until `:NotebookBootstrap` has run.
  if vim.uv.fs_stat(M.host_python()) then vim.g.python3_host_prog = M.host_python() end

  -- Starting a kernel means writing a connection file into Jupyter's runtime
  -- directory, and nothing on this machine has ever created that directory --
  -- Jupyter itself only makes it when you run `jupyter` something, which this
  -- arrangement never does. Molten catches the resulting `FileNotFoundError`
  -- and reports it through `vim.notify`, so on a fresh machine `<Leader>rr`
  -- flashes one error and then silently does nothing at all, forever.
  local runtime = jupyter_runtime_dir()
  if not vim.uv.fs_stat(runtime) then vim.fn.mkdir(runtime, "p") end

  patch_comment_stripping()

  vim.api.nvim_create_user_command("NotebookBootstrap", M.bootstrap, { desc = "Build the Molten host venv" })
  vim.api.nvim_create_user_command("NotebookHealth", M.health, { desc = "Check the notebook setup" })
  vim.api.nvim_create_user_command(
    "NotebookKernel",
    M.register_kernel,
    { desc = "Register this project's venv as a Jupyter kernel" }
  )

  -- `.ipynb` outputs. jupytext round-trips the *code*; the outputs saved in
  -- the notebook are a separate thing that only Molten knows how to place, so
  -- they are loaded on open and written back on save. Without this half, a
  -- notebook from Colab would open with all its plots missing, and saving
  -- would strip the ones you just produced.
  local group = vim.api.nvim_create_augroup("user_notebook_ipynb", { clear = true })

  vim.api.nvim_create_autocmd("BufReadPost", {
    group = group,
    pattern = "*.ipynb",
    desc = "Attach the notebook's kernel and load its saved outputs",
    callback = function(args)
      vim.schedule(function()
        if not load_molten() then return end
        if not initialized() then
          local kernels = available_kernels()
          -- The notebook records which kernel produced it. Prefer that, so a
          -- shared notebook opens against the environment it was written for;
          -- fall back to this project's own.
          local ok, saved = pcall(function()
            local f = assert(io.open(args.file, "r"))
            local text = f:read "a"
            f:close()
            return vim.json.decode(text).metadata.kernelspec.name
          end)
          local name = (ok and vim.tbl_contains(kernels, saved)) and saved or M.project_kernel()
          if not name or not vim.tbl_contains(kernels, name) then return end
          vim.cmd("MoltenInit " .. name)
        end
        pcall(vim.cmd, "MoltenImportOutput")
      end)
    end,
  })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = "*.ipynb",
    desc = "Write cell outputs back into the notebook",
    callback = function()
      -- Runs after jupytext has already written the code half of the file, so
      -- this merges outputs into a notebook that is otherwise up to date.
      -- Costs a few hundred milliseconds -- noticeable on `:w`, and the reason
      -- there is no autosave in this config.
      if initialized() then pcall(vim.cmd, "MoltenExportOutput!") end
    end,
  })
end

return M
