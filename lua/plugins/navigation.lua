-- Window and tab-page conveniences that do not replace native motions,
-- jumplist keys, buffer navigation, marks, or editing operators.
---@type LazySpec
return {
  "AstroNvim/astrocore",
  ---@param opts AstroCoreOpts
  opts = function(_, opts)
    local maps = assert(opts.mappings)

    -- Tab pages stay what Neovim defines them as: alternate window layouts.
    maps.n["<Leader>T"] = { desc = "󰓩 Tab pages" }
    maps.n["<Leader>Tn"] = { "<Cmd>tabnew<CR>", desc = "New tab page" }
    maps.n["<Leader>Tc"] = { "<Cmd>tabclose<CR>", desc = "Close tab page" }
    maps.n["<Leader>To"] = { "<Cmd>tabonly<CR>", desc = "Close other tab pages" }
    maps.n["<Leader>Tl"] = { "<Cmd>tabnext<CR>", desc = "Next tab page" }
    maps.n["<Leader>Th"] = { "<Cmd>tabprevious<CR>", desc = "Previous tab page" }

    maps.n["<Leader>sr"] = {
      function() require("smart-splits").start_resize_mode() end,
      desc = "Resize mode (hjkl, <Esc> to exit)",
    }
    maps.n["<Leader>s="] = { "<C-w>=", desc = "Equalize split sizes" }
    maps.n["<Leader>sm"] = {
      function()
        if vim.t.zoom_restore then
          vim.cmd(vim.t.zoom_restore)
          vim.t.zoom_restore = nil
        elseif vim.fn.winnr "$" > 1 then
          vim.t.zoom_restore = vim.fn.winrestcmd()
          vim.cmd "resize | vertical resize"
        end
      end,
      desc = "Zoom split (toggle)",
    }
    maps.n["<Leader>sw"] = {
      function()
        local win = require("window-picker").pick_window()
        if win then vim.api.nvim_set_current_win(win) end
      end,
      desc = "Pick a window",
    }
    maps.n["<Leader>sH"] = { function() require("smart-splits").swap_buf_left() end, desc = "Swap split left" }
    maps.n["<Leader>sJ"] = { function() require("smart-splits").swap_buf_down() end, desc = "Swap split down" }
    maps.n["<Leader>sK"] = { function() require("smart-splits").swap_buf_up() end, desc = "Swap split up" }
    maps.n["<Leader>sL"] = { function() require("smart-splits").swap_buf_right() end, desc = "Swap split right" }
  end,
}
