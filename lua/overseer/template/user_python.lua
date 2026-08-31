-- Overseer tasks for a Python project that has no justfile or Makefile.
--
-- THE PROBLEM THIS SOLVES: overseer only offers what a project *declares*. In
-- SOPA-ESP32-MK3 that's a justfile, so `<Leader>rr` lists real recipes. But a
-- plain package tree like ~/code/deep-learning declares nothing runnable, so
-- the picker came up empty -- while the thing you actually want to run is
-- always the same shape:
--
--     cd ~/code/deep-learning && uv run python -m lec5.main
--
-- The dotted name is derived from the buffer, so a `lec6/` you add tomorrow
-- works with no edit here. See `lua/user/python_target.lua` for how, and for
-- why the module form matters rather than `python lec5/main.py`.
--
-- WHY THIS FILE LIVES AT `lua/overseer/template/`: overseer discovers templates
-- by globbing `lua/overseer/template/**/*.lua` across the whole runtimepath, so
-- anything here is picked up with no registration call. Its `template_dirs`
-- option looks like the intended place for user templates, but it derives the
-- module name with a pattern that requires "overseer/template/" in the path --
-- so a directory named anything else fails to load.

local python = require "user.languages.python.target"

--- Neovim's default 'errorformat' knows nothing about Python, so a traceback
--- lands in the quickfix list as plain text with no file or line and `æq`/`øq`
--- have nothing to jump to. This turns each traceback frame
---
---     File "/home/kasper/code/deep-learning/lec5/main.py", line 12, in boom
---
--- into one quickfix entry, so the list becomes the call stack: `æq` walks
--- outward from where it blew up. The exception message itself stays in the
--- task output window, which opens alongside.
---
--- Deliberately NOT the multiline `%A`/`%C`/`%Z` form. That reads a frame and
--- its source line as one entry, which is prettier -- but a frame with no
--- source line under it (every `<frozen runpy>` frame, and `-m` always produces
--- two of those) never gets its terminator, and swallows the real frames after
--- it. Tested: it reported the two runpy frames and nothing else.
---
--- The `%-G` lines drop the frozen frames and then everything unmatched, which
--- is what keeps uv's resolver chatter out of the list.
local PYTHON_EFM = table.concat({
  "%-G%.%#<frozen%.%#", -- runpy's own frames -- not your code, not navigable
  '%*[^"]"%f"\\, line %l\\, in %m',
  '%*[^"]"%f"\\, line %l',
  "%-G%.%#",
}, ",")

--- Task components shared by both entries. `"default"` is the alias defined in
--- `lua/plugins/tasks.lua`, which is what makes the live output pane open when
--- the task starts.
---
--- `open_on_match = false` on purpose. Popping the quickfix window open would
--- land it at the bottom of the screen -- exactly where the output pane you are
--- reading the traceback in already is. The entries are still filled, so `æq` /
--- `øq` walk the stack without any window, and `<Leader>xq` opens the list if
--- you want to see it whole.
local COMPONENTS = {
  "default",
  { "on_output_quickfix", errorformat = PYTHON_EFM, open_on_match = false, items_only = true },
}

-- A KNOWN LIMIT OF THE QUICKFIX PARSING ABOVE, so it does not surprise you:
-- task output goes through a terminal, and a terminal hard-wraps at the window
-- width. A frame line is long --
--
--     File "/home/kasper/code/deep-learning/lec5/main.py", line 12, in boom
--
-- -- about 70 columns for this project. If the task window is narrower than the
-- line, it wraps mid-path, `%f` never finds its closing quote, and that frame
-- does not become a quickfix entry. Widening the window fixes it.
--
-- The fully robust alternative is a non-terminal buffer
-- (`strategy = { "jobstart", use_terminal = false }`), which hands the lines
-- over intact at any width. It is deliberately not used: without a TTY, tqdm
-- and torch progress bars print one line per update instead of redrawing in
-- place, and for a deep-learning project watching a training run matters more
-- than jumping to a frame. The full traceback is always in the task output
-- window regardless -- the quickfix is the convenience, not the record.

---@type overseer.TemplateFileProvider
return {
  name = "user_python",
  condition = { filetype = { "python" } },

  generator = function(_, cb)
    local target = python.resolve()
    if not target then return cb {} end

    local pretty_root = vim.fn.fnamemodify(target.root, ":~")
    local tmpls = {}

    if target.module then
      table.insert(tmpls, {
        name = python.module_template_name(target),
        desc = string.format("%s, from %s", target.label, pretty_root),
        tags = { "RUN" },
        builder = function()
          return {
            cmd = vim.list_extend(vim.deepcopy(target.py), { "-m", target.module }),
            -- The project root -- the directory `-m` puts on sys.path.
            cwd = target.root,
            components = COMPONENTS,
          }
        end,
      })
    end

    table.insert(tmpls, {
      name = string.format("python %s", vim.fn.fnamemodify(target.file, ":.")),
      desc = string.format("%s, run the file directly (no package context)", target.label),
      tags = { "RUN" },
      builder = function()
        return {
          cmd = vim.list_extend(vim.deepcopy(target.py), { target.file }),
          cwd = target.root,
          components = COMPONENTS,
        }
      end,
    })

    cb(tmpls)
  end,
}
