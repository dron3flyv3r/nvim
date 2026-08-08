-- Faster buffer/tab switching and window resizing.
--
-- ON SCOPED BUFFER SETS: Neovim buffers are global -- a window cannot own its
-- own set of them, and no plugin really changes that. What AstroNvim *does*
-- give you is a per-TAB-PAGE buffer list (`vim.t.bufs`), which is what the
-- tabline draws and what `]b`/`<Tab>`/`<Leader>1..9` navigate. Splits inside
-- one tab share that list; a new tab page starts an empty one.
--
-- So a tab page is the "separate working set" unit. `<Leader>Tn` opens one,
-- and from then on the tabline and every buffer key below are scoped to it.
---@type LazySpec
return {
  "AstroNvim/astrocore",
  ---@type AstroCoreOpts
  opts = function(_, opts)
    local maps = opts.mappings
    local buffer = function(fn, ...)
      local args = { ... }
      return function() require("astrocore.buffer")[fn](unpack(args)) end
    end

    -- ── Buffers (scoped to the current tab page) ──────────────────────────
    maps.n["<Tab>"] = { buffer("nav", 1), desc = "Next buffer" }
    maps.n["<S-Tab>"] = { buffer("nav", -1), desc = "Previous buffer" }

    -- Jump straight to the Nth buffer in the tabline. `<Leader>N` always works;
    -- `<A-N>` is the one-handed version and is free here (mini.move only claims
    -- Alt+hjkl).
    for i = 1, 9 do
      maps.n["<Leader>" .. i] = { buffer("nav_to", i), desc = "Buffer " .. i }
      maps.n["<A-" .. i .. ">"] = { buffer("nav_to", i), desc = "Buffer " .. i }
    end

    -- `<Tab>` and `<C-i>` are the same byte on a terminal without the kitty
    -- keyboard protocol, so mapping Tab can cost you jump-forward. Keep a
    -- spelling that can never collide.
    maps.n["<Leader>i"] = { "<C-i>", desc = "Jump forward (jumplist)" }
    maps.n["<Leader>o"] = { "<C-o>", desc = "Jump back (jumplist)" }

    -- ── Moving and duplicating lines ──────────────────────────────────────
    -- mini.move (from astrocommunity) already owns <A-hjkl> in normal and
    -- visual mode: j/k move the line or selection down/up, h/l move it left and
    -- right -- which for a line means dedent and indent, so "in and out" is the
    -- same four keys. It respects counts (3<A-j>) and folds a whole run of
    -- moves into one `u`.
    --
    -- What it does not do is insert mode, so add the vertical pair here -- same
    -- keys, so you never have to think about which mode you're in.
    --
    -- Only the vertical pair: <A-l> in insert mode is already copilot's
    -- `accept_line` (see copilot.lua), and insert mode has had native
    -- indent/dedent since forever -- <C-t> and <C-d>. Nothing to add.
    local move = function(direction) return function() require("mini.move").move_line(direction) end end
    maps.i["<A-j>"] = { move "down", desc = "Move line down" }
    maps.i["<A-k>"] = { move "up", desc = "Move line up" }

    -- Duplicate, on the shifted version of the same keys: <A-S-j> leaves the
    -- copy below and puts you on it, <A-S-k> leaves the copy above.
    --
    -- Visual mode needs the marks: `y` drops you at the *start* of what you
    -- yanked, so pasting there would bury the original. Jump to `> (end of the
    -- selection) and paste after it, or to `< and paste before it.
    maps.n["<A-S-j>"] = { "<Cmd>t.<CR>", desc = "Duplicate line below" }
    maps.n["<A-S-k>"] = { "<Cmd>t-1<CR>", desc = "Duplicate line above" }
    maps.i["<A-S-j>"] = { "<Cmd>t.<CR>", desc = "Duplicate line below" }
    maps.i["<A-S-k>"] = { "<Cmd>t-1<CR>", desc = "Duplicate line above" }
    maps.x["<A-S-j>"] = { "y`>p", desc = "Duplicate selection below" }
    maps.x["<A-S-k>"] = { "y`<P", desc = "Duplicate selection above" }

    -- ── Going somewhere and coming back ───────────────────────────────────
    -- Vim's built-in answer is the ` mark and the jumplist, but both live on
    -- keys a Danish layout makes expensive (`` is a dead key, <C-i>/<C-o> are
    -- fine but pair badly with <Tab> above). So give them plain keys.
    --
    -- <BS> is the workhorse: any *jump* (gg, G, /search, {, }, a mark, a
    -- definition jump) drops the ` mark where you left, so <BS> snaps back to
    -- the exact line and column -- and pressing it again returns to where you
    -- just were. Go to the top, add your import, <BS>, keep typing.
    maps.n["<BS>"] = { "``", desc = "Back to position before last jump (toggles)" }

    -- Editing does not count as a jump, so for "take me back to what I was
    -- last *changing*" you want the changelist instead.
    maps.n["<Leader><BS>"] = { "g;", desc = "Back to last edit" }

    -- Explicit anchor, for when you will make jumps in between and don't want
    -- to rely on ` surviving them. Uses the uppercase mark Z (file-global, so
    -- it works across buffers too) and is deliberately a matched pair.
    maps.n["<Leader>ma"] = {
      function()
        vim.cmd "normal! mZ"
        require("astrocore").notify("Anchor set -- <Leader>mj to return", vim.log.levels.INFO)
      end,
      desc = "Set anchor here",
    }
    maps.n["<Leader>mj"] = { "`Z", desc = "Jump to anchor" }
    maps.n["<Leader>m"] = { desc = "󰃀 Marks" }

    -- ── Tab pages = independent buffer sets ───────────────────────────────
    maps.n["<Leader>T"] = { desc = "󰓩 Tabs" }
    maps.n["<Leader>Tn"] = { "<Cmd>tabnew<CR>", desc = "New tab (fresh buffer set)" }
    maps.n["<Leader>Tc"] = { "<Cmd>tabclose<CR>", desc = "Close tab" }
    maps.n["<Leader>To"] = { "<Cmd>tabonly<CR>", desc = "Close all other tabs" }
    maps.n["<Leader>Tl"] = { "<Cmd>tabnext<CR>", desc = "Next tab" }
    maps.n["<Leader>Th"] = { "<Cmd>tabprevious<CR>", desc = "Previous tab" }

    -- ── Window resizing ───────────────────────────────────────────────────
    -- `<C-arrows>` already nudge one step at a time (AstroNvim wires those to
    -- smart-splits). Resize *mode* is the better tool for real adjustment:
    -- press once, then h/j/k/l as much as you like, <Esc> or q to leave.
    maps.n["<Leader>sr"] = {
      function() require("smart-splits").start_resize_mode() end,
      desc = "Resize mode (hjkl, <Esc> to exit)",
    }
    maps.n["<Leader>s="] = { "<C-w>=", desc = "Equalize split sizes" }
    maps.n["<Leader>sm"] = { "<Cmd>resize | vertical resize<CR>", desc = "Maximise split" }

    -- Swap the current split with a neighbour, for when the layout is right
    -- but the contents are in the wrong panes.
    maps.n["<Leader>sH"] = { function() require("smart-splits").swap_buf_left() end, desc = "Swap split left" }
    maps.n["<Leader>sJ"] = { function() require("smart-splits").swap_buf_down() end, desc = "Swap split down" }
    maps.n["<Leader>sK"] = { function() require("smart-splits").swap_buf_up() end, desc = "Swap split up" }
    maps.n["<Leader>sL"] = { function() require("smart-splits").swap_buf_right() end, desc = "Swap split right" }
  end,
}
