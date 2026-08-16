-- `<Leader>ln` -- create a C++ class, interface or class template: both files,
-- the include between them, and the line in CMakeLists.
--
-- All of the reasoning is in `lua/user/cpp_scaffold.lua`; this file is the
-- wiring. The short version is that it reads the project's existing files to
-- decide file name case, header extension, guard style, namespace and target
-- directory, so it produces snake_case flat pairs in SOPA-ESP32-MK3 and
-- `src/`-rooted files in evlo-sim-mk1 without being told which is which.
--
-- WHY THE KEYS ARE ON THE FILETYPE and not on clangd, unlike `<Leader>lc` next
-- door in `refactor.lua`: creating a file is not a language-server operation.
-- It has to work in a project clangd has not indexed, in a sketch with no
-- `compile_commands.json`, and -- via `:CppNew` -- in a buffer that is not C++
-- at all. Gating it on an LSP attach would take it away in exactly the
-- situation it is most useful: the empty project with one `main.cpp` in it.
--
-- The prompt takes a path, not just a name: `audio/mixer` puts the pair in an
-- `audio/` subdirectory (created if needed) of wherever the bare name would have
-- landed, and a leading slash measures that path from the project root instead.
--
-- `:CppNew {class|interface|template}` is the same thing without the filetype
-- requirement, for creating the first C++ file in a project from wherever you
-- happen to be.

--- The `<Leader>ln` keys, on the buffer rather than globally.
---
--- Same reasoning as `<Leader>C` in `cpp-cmake.lua`: globally these would be
--- dead weight in every Python and Lua buffer and which-key would offer a
--- "New (C++)" menu while you are editing a notebook.
---@param bufnr integer
local function set_mappings(bufnr)
  local scaffold = require "user.cpp_scaffold"
  require("astrocore").set_mappings({
    n = {
      -- `FileNew` (), AstroUI's icon for a file that does not exist yet.
      -- `get_icon` returns "" for a name it does not have, so a wrong guess
      -- here is silent rather than an error -- see the note on `<Leader>r` in
      -- `tasks.lua`.
      ["<Leader>ln"] = { desc = require("astroui").get_icon("FileNew", 1, true) .. "New (C++)" },

      -- The one you press. Header plus source, an out-of-line default
      -- constructor in the .cpp, and the .cpp added to the CMake target that
      -- already compiles that directory.
      ["<Leader>lnc"] = { function() scaffold.create "class" end, desc = "New class (.h + .cpp)" },

      -- Both header-only, and for different reasons -- an interface has
      -- nothing to put in a .cpp, a template must not have one at all or it
      -- fails at link time. See the template comments in `cpp_scaffold.lua`.
      ["<Leader>lni"] = { function() scaffold.create "interface" end, desc = "New interface (abstract base)" },
      ["<Leader>lnt"] = { function() scaffold.create "template" end, desc = "New class template" },
    },
  }, { buffer = bufnr })
end

---@type LazySpec
return {
  "AstroNvim/astrocore",
  ---@param opts AstroCoreOpts
  opts = function(_, opts)
    local autocmds = opts.autocmds or {}
    autocmds.cpp_scaffold_mappings = {
      {
        event = "FileType",
        -- No `cmake` here, unlike `cpp-cmake.lua`: these create C++ *source*,
        -- which is not a thing you want a key for while editing a build file.
        pattern = { "c", "cpp", "objc", "objcpp", "cuda" },
        desc = "Add the <Leader>ln create-file mappings to C-family buffers",
        callback = function(args) set_mappings(args.buf) end,
      },
    }
    opts.autocmds = autocmds

    opts.commands = opts.commands or {}
    opts.commands.CppNew = {
      function(args) require("user.cpp_scaffold").create(args.args ~= "" and args.args or "class") end,
      desc = "Create a C++ class, interface or class template",
      nargs = "?",
      complete = function() return { "class", "interface", "template" } end,
    }
  end,
}
