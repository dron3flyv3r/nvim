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
      header_extension = "h",
      source_extension = "cpp",
      custom_define_class_function_commands = {
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
