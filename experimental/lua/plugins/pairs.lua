---@type LazySpec
return {
  "echasnovski/mini.pairs",
  version = "*",
  event = "InsertEnter",
  -- The FileType handler is registered here rather than in `config` because the
  -- picker sets its filetype before the first InsertEnter loads the plugin.
  init = function()
    vim.api.nvim_create_autocmd("FileType", {
      group = vim.api.nvim_create_augroup("plugins_pairs", {}),
      pattern = { "snacks_picker_input", "snacks_input" },
      callback = function(args) vim.b[args.buf].minipairs_disable = true end,
      desc = "No pairing in a prompt, where an unclosed bracket is a search term",
    })
  end,
  opts = {
    mappings = {
      ["'"] = false,
      ["`"] = false,
    },
  },
}
