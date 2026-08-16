-- `<Leader>lcp` -- write the .cpp definitions for declarations in the header.
--
-- THE GAP THIS FILLS, and the reason it needs a plugin at all: clangd cannot do
-- this. `<Leader>lco` (DefineOutline) *moves* a body that already exists from
-- the header to the .cpp -- it needs something to move. Put the cursor on a
-- bare `void reset();` that has no definition anywhere and clangd offers
-- nothing at all; there is no "add definition" tweak, and asking for code
-- actions on that line returns an empty list. That is the one operation in the
-- "IDE refactoring" set that the language server genuinely does not have.
--
-- nt-cpp-tools does it from the treesitter tree instead, which is why it works
-- on a declaration with no definition to reason about -- it is reading the
-- syntax, not the semantics. It also means it works in a sketch with no
-- `compile_commands.json`, where clangd is half blind.
--
-- HOW THE TWO HALVES DIVIDE UP, since the menu now has both:
--
--   declared it, never wrote it        -> `<Leader>lcp`  (this file)
--   wrote it inline, want it in .cpp   -> `<Leader>lco`  (clangd, refactor.lua)
--   wrote it in .cpp, want it inline   -> `<Leader>lci`  (clangd, refactor.lua)
--   changed the signature, out of sync -> `<Leader>lci`, edit, `<Leader>lco`
--
-- That last one is worth spelling out because it is not obvious and it is the
-- answer to "how do I keep them in sync when I change the parameters". There is
-- no change-signature refactoring for C++ in Neovim -- clangd detects the drift
-- exactly ("Out-of-line definition of 'scaled' does not match any declaration
-- in 'Widget'") but offers no fix for it. What does work is removing the
-- duplication for a moment: `<Leader>lci` pulls the body up onto the
-- declaration, so the signature exists in exactly one place; edit it there;
-- `<Leader>lco` pushes it back down. Two keys and one edit, and the two files
-- cannot disagree in between because there is only one of them.
--
-- IT DOES NOT SKIP WHAT IS ALREADY IMPLEMENTED. Run it twice over the same
-- declarations and you get two copies of every definition; it generates from
-- the declarations in the range and never looks in the .cpp to see what is
-- there. So the range is the control: put the cursor on the one declaration
-- you just added, or select the three you just added, rather than selecting
-- the whole class every time. Getting it wrong is loud rather than subtle --
-- clangd flags the redefinition immediately -- but it is still an undo.
--
-- WHY NOT ITS RuleOf3 / RuleOf5 COMMANDS: they add the copy/move constructor
-- and assignment declarations to a class, which is exactly what clangd's
-- `Declare implicit copy/move members` already does on `<Leader>lcm`. One
-- keymap per operation; the clangd one wins because it knows which members the
-- class actually needs rather than which ones the rule names.
--
-- WHY NOT `TSCppMakeConcreteClass`, which would otherwise pair nicely with the
-- interface template on `<Leader>lni`: it is broken against the current
-- tree-sitter-cpp grammar and throws rather than failing quietly --
--
--     Query error at 6:10. Invalid node type "virtual"
--
-- Its `concrete_implement.scm` matches `(virtual)` as a named node and expects
-- the `= 0` under a `default_value:` field. In the grammar shipping today
-- `virtual` is an anonymous token and the `0` is a bare `number_literal` child,
-- so the query no longer compiles. `outside_class_def.scm` -- the one the two
-- keys above depend on -- is unaffected and works. Fixing it would mean
-- shadowing a third-party plugin's internal query from this config, which is
-- more upkeep than a command neither project here has asked for is worth.

--- The nt-cpp-tools keys, on the buffer.
---
--- These hang off `<Leader>lc` -- the refactor menu from `refactor.lua` -- but
--- are set from a FileType event rather than an LspAttach, because unlike
--- everything else in that menu they do not need clangd. A C++ buffer is the
--- only requirement. (`refactor.lua` owns the group's which-key description, so
--- there is none here; a second one would just be a duplicate entry.)
---@param bufnr integer
local function set_mappings(bufnr)
  require("astrocore").set_mappings({
    n = {
      -- Cursor on a declaration -> that one. The command takes a `-range` and
      -- defaults it to the current line.
      ["<Leader>lcp"] = { "<Cmd>TSCppImplWrite<CR>", desc = "Implement declaration(s) in the .cpp" },
      ["<Leader>lcP"] = { "<Cmd>TSCppDefineClassFunc<CR>", desc = "Implement declaration(s) here (preview)" },
    },
    x = {
      -- `:` and not `<Cmd>`: pressing `:` in visual mode is what inserts the
      -- `'<,'>` range these commands read. `<Cmd>` skips the command line
      -- entirely, so the range would silently fall back to the cursor line and
      -- only the first declaration of the selection would be implemented.
      ["<Leader>lcp"] = { ":TSCppImplWrite<CR>", desc = "Implement selected declarations in the .cpp" },
      ["<Leader>lcP"] = { ":TSCppDefineClassFunc<CR>", desc = "Implement selected declarations here (preview)" },
    },
  }, { buffer = bufnr })
end

---@type LazySpec
return {
  "Badhi/nvim-treesitter-cpp-tools",
  -- The lua module is `nt-cpp-tools`, not the repository name, so lazy cannot
  -- derive it -- without this `opts` is built and then handed to a `setup` that
  -- does not exist, and the commands are never created.
  main = "nt-cpp-tools",
  ft = { "c", "cpp", "objcpp", "cuda" },
  dependencies = { "nvim-treesitter/nvim-treesitter" },
  -- A function, not a table: the `output_handlers` require below has to happen
  -- when the plugin is being configured, not while lazy is reading specs at
  -- startup -- which is also when `opts` tables get evaluated.
  opts = function()
    return {
      preview = {
        quit = "q",
        -- `<Tab>` accepts the preview. Only live inside the preview window, so
        -- it does not collide with completion.
        accept = "<Tab>",
      },
      -- Used by the "write to the .cpp" handler to find the source file, by
      -- swapping the extension on the current path. Both are this project's
      -- defaults and match every C++ file in ~/code.
      --
      -- THE LIMIT OF THAT: it is a string swap on the current file's path, so
      -- it finds `widget.cpp` next to `widget.h` and nothing else. In an
      -- `include/proj/foo.hpp` + `src/foo.cpp` layout it will offer to create
      -- `include/proj/foo.cpp`, which is not where the source belongs -- use
      -- `<Leader>lcP` there and paste, or run it from the .cpp side. Neither
      -- project here is laid out that way.
      header_extension = "h",
      source_extension = "cpp",
      custom_define_class_function_commands = {
        -- The plugin only creates `TSCppDefineClassFunc` itself, which previews
        -- and then inserts into the *current* buffer -- right for a
        -- header-only class, wrong for the case this file exists for. This is
        -- the same generator with the "write it into the .cpp" output handler,
        -- and it is what `<Leader>lcp` calls.
        TSCppImplWrite = {
          output_handle = require("nt-cpp-tools.output_handlers").get_add_to_cpp(),
        },
      },
    }
  end,
  config = function(_, opts)
    require("nt-cpp-tools").setup(opts)

    local FILETYPES = { "c", "cpp", "objcpp", "cuda" }

    -- The buffer that triggered `ft = {...}` has already fired its FileType
    -- event by the time this runs, so it would be the one buffer without the
    -- mappings. Map what is open, then map what arrives later.
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(bufnr) and vim.tbl_contains(FILETYPES, vim.bo[bufnr].filetype) then
        set_mappings(bufnr)
      end
    end

    vim.api.nvim_create_autocmd("FileType", {
      group = vim.api.nvim_create_augroup("cpp_implement_mappings", { clear = true }),
      pattern = FILETYPES,
      desc = "Add the <Leader>lc implement mappings to C++ buffers",
      callback = function(args) set_mappings(args.buf) end,
    })
  end,
}
