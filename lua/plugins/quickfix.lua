---@type LazySpec
return {
  "AstroNvim/astrocore",
  ---@param opts AstroCoreOpts
  opts = function(_, opts)
    -- Guaranteed by `astrocore.lua`, which sets `mappings` in its static opts;
    -- `assert` says so to the type checker instead of nil-checking every line.
    local maps = assert(opts.mappings)

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

    local code_action = require("user.quick_fix").code_action(vim.lsp.buf.code_action)
    maps.n["gra"] = { code_action, desc = "LSP code action" }
    maps.x["gra"] = { code_action, desc = "LSP code action" }
    maps.n["<Leader>xa"] = { code_action, desc = "Quick Fix (code action)" }
    maps.x["<Leader>xa"] = { code_action, desc = "Quick Fix (code action)" }
  end,
}
