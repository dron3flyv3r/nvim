return {
  -- Ensure <CR> falls back to a real newline when completion isn't visible
  {
    "hrsh7th/nvim-cmp",
    opts = function(_, opts)
      local cmp = require "cmp"
      opts.mapping = vim.tbl_extend("force", opts.mapping or {}, {
        ["<CR>"] = cmp.mapping(function(fallback)
          if cmp.visible() then
            cmp.confirm { select = false } -- confirm only when menu is open
          else
            fallback() -- real newline
          end
        end, { "i", "s" }),
        ["<C-m>"] = cmp.mapping(function(fallback)
          if cmp.visible() then
            cmp.confirm { select = false }
          else
            fallback()
          end
        end, { "i", "s" }),
      })
    end,
  },

  -- Avoid nvim-autopairs hijacking <CR>
  {
    "windwp/nvim-autopairs",
    opts = function(_, opts)
      opts = opts or {}
      opts.map_cr = false -- disable its <CR> mapping
      return opts
    end,
    config = function(_, opts)
      require("nvim-autopairs").setup(opts)
      -- keep the cmp integration (pairs on confirm) without mapping <CR>
      local cmp_ok, cmp = pcall(require, "cmp")
      if cmp_ok then
        local cmp_autopairs = require "nvim-autopairs.completion.cmp"
        cmp.event:on("confirm_done", cmp_autopairs.on_confirm_done())
      end
    end,
  },
}
