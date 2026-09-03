-- Kernel, execution, bootstrap, and persistence behind contextual notebook
-- actions. Cell boundaries live in `notebook/cells.lua`; the overall design is
-- documented in `docs/decisions/notebooks.md`.

local M = {}
local cells = require "user.integrations.notebook.cells"

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

---@return boolean
local function initialized()
  local ok, kernels = pcall(vim.fn.MoltenRunningKernels, true)
  return ok and type(kernels) == "table" and not vim.tbl_isempty(kernels)
end

---@return string
local function jupyter_runtime_dir()
  if vim.env.JUPYTER_RUNTIME_DIR then return vim.env.JUPYTER_RUNTIME_DIR end
  local data = vim.env.JUPYTER_DATA_DIR
    or vim.fs.joinpath(vim.env.XDG_DATA_HOME or vim.fs.joinpath(vim.env.HOME, ".local", "share"), "jupyter")
  return vim.fs.joinpath(data, "runtime")
end

M.cell_starts = cells.starts
M.cell_bounds = cells.bounds
M.goto_cell = cells.goto_cell
M.insert_cell = cells.insert

--- Jupyter kernel names this machine knows about.
---@return string[]
local function available_kernels()
  local ok, kernels = pcall(vim.fn.MoltenAvailableKernels)
  if not ok or type(kernels) ~= "table" then return {} end
  return kernels
end

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
          ("Kernel `%s` registered -- run a cell from <Leader>ra"):format(name),
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

---@param first integer
---@param last integer
local function evaluate(first, last) vim.fn.MoltenEvaluateRange(first, last) end

--- Evaluate the cell under the cursor.
---@param advance boolean move to the next cell afterwards (Colab's Shift+Enter)
function M.run_cell(advance)
  local first, last = M.cell_bounds()
  -- Shift+Enter on a text cell in a notebook moves on rather than complaining,
  -- and so does this.
  if cells.is_prose(first) then
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
      if not cells.is_prose(s) then evaluate(s, (starts[i + 1] or total + 1) - 1) end
    end
  end)
end

--- Evaluate the current line, or the visual selection.
---@param mode "line"|"visual"
function M.run(mode)
  M.with_kernel(function() vim.cmd(mode == "visual" and "MoltenEvaluateVisual" or "MoltenEvaluateLine") end)
end

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

---@return "kitty"|"sixel"
function M.image_backend()
  if vim.env.KITTY_WINDOW_ID or vim.env.TERM == "xterm-kitty" then return "kitty" end
  if vim.env.GHOSTTY_RESOURCES_DIR or vim.env.GHOSTTY_BIN_DIR then return "kitty" end
  if vim.env.WEZTERM_PANE then return "kitty" end
  return "sixel"
end

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

--- Point Neovim's Python host at the Molten venv, register the commands, and
--- set up the `.ipynb` output round-trip. Called from the Molten spec's `init`,
--- so it runs at startup even though Molten itself is lazy.
function M.setup()
  -- Only if it is actually there: a broken `python3_host_prog` breaks every
  -- Python remote plugin, and pointing at a venv that does not exist yet is
  -- worse than leaving the default alone until `:NotebookBootstrap` has run.
  if vim.uv.fs_stat(M.host_python()) then vim.g.python3_host_prog = M.host_python() end

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
      if initialized() then pcall(vim.cmd, "MoltenExportOutput!") end
    end,
  })
end

return M
