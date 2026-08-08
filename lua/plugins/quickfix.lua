-- Making `<Leader>x` (the quickfix list) actually useful.
--
-- WHY `<Leader>xq` LOOKED BROKEN -- two separate reasons:
--
--   1. `uv.nvim` defaults its keymap prefix to `<Leader>x`, the same prefix
--      AstroNvim uses for the quickfix list. That is fixed in `uv.lua`, which
--      moves uv to `<Leader>v`.
--
--   2. `<Leader>xq` runs `:copen`, which opens the quickfix list -- and the
--      quickfix list starts *empty*. It is not a diagnostics view. Something
--      has to put results in it first: `:grep`, `:make`, a picker sent to
--      quickfix, or `vim.diagnostic.setqflist()`. Opening it before then
--      correctly shows nothing.
--
-- So `<Leader>xd` below fills it from the diagnostics you can already see.
-- That gives the "list every problem, walk them one at a time" workflow, with
-- `]q` / `[q` (or `æq` / `øq`) to step through.
--
-- NOTE: VS Code's "Quick Fix" (the lightbulb, Ctrl+.) is NOT this. That is a
-- code action, and it is `<Leader>la`. The `help: Organize imports` and
-- `help: Replace with ...` hints in the virtual text are code actions waiting
-- for `<Leader>la`.
---@type LazySpec
return {
  "AstroNvim/astrocore",
  ---@type AstroCoreOpts
  opts = function(_, opts)
    local maps = opts.mappings

    --- Fill a list from diagnostics and say so when there is nothing to fill it
    --- with -- the silence is what made this look broken in the first place.
    local function to_list(setter, empty_msg, list_opts)
      return function()
        setter(vim.tbl_extend("force", { open = true }, list_opts or {}))
        local list = setter == vim.diagnostic.setqflist and vim.fn.getqflist() or vim.fn.getloclist(0)
        if vim.tbl_isempty(list) then vim.notify(empty_msg, vim.log.levels.INFO) end
      end
    end

    maps.n["<Leader>xd"] = { to_list(vim.diagnostic.setqflist, "No diagnostics"), desc = "Diagnostics → quickfix" }
    maps.n["<Leader>xe"] = {
      to_list(vim.diagnostic.setqflist, "No errors", { severity = vim.diagnostic.severity.ERROR }),
      desc = "Errors only → quickfix",
    }
    maps.n["<Leader>xb"] = {
      to_list(vim.diagnostic.setloclist, "No diagnostics in this buffer"),
      desc = "Buffer diagnostics → location list",
    }

    maps.n["<Leader>xc"] = { "<Cmd>cclose | lclose<CR>", desc = "Close quickfix/location list" }

    -- `<Leader>la` is the real "Quick Fix". Mirror it here for muscle memory
    -- arriving from VS Code, where it lives on Ctrl+`.`.
    local code_action = function() vim.lsp.buf.code_action() end
    maps.n["<Leader>xa"] = { code_action, desc = "Quick Fix (code action)" }
    maps.x["<Leader>xa"] = { code_action, desc = "Quick Fix (code action)" }
  end,
}
