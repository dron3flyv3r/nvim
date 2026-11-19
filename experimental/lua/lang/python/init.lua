require("lang.python.venv").setup()

vim.api.nvim_create_autocmd("FileType", {
  group = vim.api.nvim_create_augroup("lang_python_buffer", { clear = true }),
  pattern = "python",
  callback = function(event)
    vim.api.nvim_buf_create_user_command(event.buf, "PythonHover", function()
      if #vim.lsp.get_clients { bufnr = event.buf, method = "textDocument/hover" } == 0 then
        return vim.notify("Python hover is unavailable. Check attached servers with :ActionsStatus.")
      end
      vim.lsp.buf.hover()
    end, { nargs = "*" })
    vim.bo[event.buf].keywordprg = ":PythonHover"
    if vim.treesitter.language.add "python" and vim.treesitter.query.get("python", "highlights") then
      vim.treesitter.start(event.buf, "python")
    end
  end,
})

---@type lang.Module
return {
  ft = { "python" },

  -- Absent when no server is installed: `vim.lsp.enable` on a missing `cmd`
  -- warns at every matching FileType from then on.
  lsp = require("lang.python.lsp").config(),

  dap = {
    adapters = { python = require("lang.python.debugpy").resolve },
  },

  actions = require "lang.python.actions",
}
