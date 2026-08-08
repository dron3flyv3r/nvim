-- Multiple cursors, VSCode-style.
--
-- Renaming a *variable* is not this plugin's job -- that's `grn`, the LSP
-- rename, which understands scope and follows the symbol across files. Reach
-- for multiple cursors when there is no symbol to rename: repeated string
-- literals, a column of dict keys, wrapping ten lines in the same call.
--
-- WHY THIS IS HAND-WRITTEN AND NOT `astrocommunity.editing-support.vim-visual-multi`:
-- that module has two bugs. Its add-cursor mapping is `"<C-U>call vm#...<CR>"`
-- with no leading `:`, so in normal mode it scrolls half a page and then feeds
-- `call ...` to the editor as keystrokes. And it registers the keys as
-- `<C-up>`/`<C-down>` while AstroNvim registers `<C-Up>`/`<C-Down>` for
-- smart-splits resize -- different string keys in the same Lua table, so which
-- one survives depends on table iteration order. It really does come out
-- different per key.
--
-- Letting the plugin install its own mappings (as upstream intends) avoids
-- both: VM is lazy-loaded, so its maps land after AstroNvim's and win cleanly.
---@type LazySpec
return {
  {
    "mg979/vim-visual-multi",
    event = { "User AstroFile", "InsertEnter" },
    init = function()
      -- VM reads all of these at load time, so they must be set in `init`.
      vim.g.VM_silent_exit = 1 -- no "Exited Visual-Multi" message on every <Esc>
      vim.g.VM_show_warnings = 0

      -- VM's leader defaults to `\`, which on a Danish keyboard is AltGr+<.
      -- Everything under it is therefore effectively unreachable, so move the
      -- one command worth having to a plain key. (`<Leader>` here is Space; VM
      -- builds these with :nmap, so the <Leader> spelling expands normally.)
      --
      -- Not `<Leader>a` for the second one, tempting as it is: that is the AI
      -- group (`<Leader>ac`, `<Leader>as`, ...) and mapping Space-a directly
      -- would swallow the whole submenu.
      vim.g.VM_maps = {
        ["Select All"] = "<Leader>A", -- every occurrence in the buffer, at once
        ["Add Cursor At Pos"] = "<Leader>N", -- drop a bare cursor where you are
      }
    end,
  },
  {
    "AstroNvim/astrocore",
    ---@param opts AstroCoreOpts
    opts = function(_, opts)
      -- Leaving VM restores 'cmdheight' from under nvim's feet, which lands you
      -- in a hit-enter prompt. Put it back on the next tick.
      opts.autocmds = opts.autocmds or {}
      opts.autocmds.visual_multi_exit = {
        {
          event = "User",
          pattern = "visual_multi_exit",
          desc = "Avoid a spurious hit-enter prompt when leaving vim-visual-multi",
          callback = function()
            vim.o.cmdheight = 1
            vim.schedule(function() vim.o.cmdheight = vim.tbl_get(opts, "options", "opt", "cmdheight") or 1 end)
          end,
        },
      }

      -- VM claims <C-Up>/<C-Down> for adding cursors vertically, which costs
      -- you AstroNvim's one-step vertical split resize. <C-Left>/<C-Right>
      -- still resize horizontally, and `<Leader>sr` resize mode (see
      -- navigation.lua) is the better tool for real resizing anyway -- but
      -- keep a vertical pair that VM cannot take.
      -- Guaranteed by `astrocore.lua`, which sets `mappings` in its static opts.
      local maps = assert(opts.mappings)
      maps.n["<Leader>sk"] = { function() require("smart-splits").resize_up() end, desc = "Resize split up" }
      maps.n["<Leader>sj"] = { function() require("smart-splits").resize_down() end, desc = "Resize split down" }
    end,
  },
}
