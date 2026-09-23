-- A short list of files worth bouncing between, scoped per git repository and
-- persisted across restarts. Deliberately coarse: it answers "the four files I
-- am living in", not "this exact line" -- marks and `<Leader>sm` still do that.
--
-- Unmaintained upstream since 2024-09-29, so the lockfile pin is the version
-- that matters. Nothing else in the config depends on it.
---@param tags grapple.tag[]
---@return string[]
local function labels(tags)
  local tails = {}
  for _, tag in ipairs(tags) do
    local tail = vim.fs.basename(tag.path)
    tails[tail] = (tails[tail] or 0) + 1
  end
  return vim.tbl_map(function(tag)
    local tail = vim.fs.basename(tag.path)
    if tails[tail] == 1 then return tail end
    return vim.fs.basename(vim.fs.dirname(tag.path)) .. "/" .. tail
  end, tags)
end

---@param ctx core.statusline.Context
---@return string?
local function tag_list(ctx)
  if not package.loaded.grapple then return nil end
  local tags = require("grapple").tags()
  if not tags or #tags == 0 then return nil end

  local current = vim.api.nvim_buf_get_name(ctx.bufnr)
  local out = {}
  for index, label in ipairs(labels(tags)) do
    local text = ("%d %s"):format(index, label):gsub("%%", "%%%%")
    local group = tags[index].path == current and "DiagnosticInfo" or "Comment"
    out[#out + 1] = ("%%#%s#%s%%#StatusLine#"):format(group, text)
  end
  return "󰛢 " .. table.concat(out, "  ")
end

---@type LazySpec
return {
  "cbochs/grapple.nvim",
  -- Icons are not decoration here: `tag_content.lua` raises a hard error when
  -- this is missing and `icons` is on. snacks finds it too and uses it for
  -- picker icons, so it earns its place twice.
  dependencies = { "nvim-tree/nvim-web-devicons" },
  cmd = "Grapple",
  -- The statusline shows the tags from startup, and a statusline expression
  -- cannot load a plugin: it runs under textlock.
  event = "VeryLazy",
  init = function()
    require("core.statusline").register(
      "grapple",
      { side = "left", order = 20, min_width = 100, raw = true, text = tag_list }
    )
    vim.api.nvim_create_autocmd("User", {
      group = vim.api.nvim_create_augroup("grapple_status", { clear = true }),
      pattern = { "GrappleUpdate", "GrappleScopeChanged" },
      desc = "Redraw the statusline when the tag list changes",
      callback = function() vim.cmd.redrawstatus() end,
    })
  end,
  ---@module 'grapple'
  ---@type grapple.settings
  opts = {
    -- One list per repository rather than per branch. `git_branch` gives each
    -- feature branch its own list, which is tidier but loses the list on every
    -- checkout. Both fall back to the working directory outside a repo.
    scope = "git",
  },
  keys = {
    { "<Leader>m", function() require("grapple").toggle() end, desc = "Toggle grapple tag" },
    { "<Leader>M", function() require("grapple").toggle_tags() end, desc = "Grapple tags" },

    -- `]g`/`[g` on a Danish layout is `øg`/`æg` through the bracket aliases in
    -- core/keymaps.lua. `]m` and `]t` are taken by Neovim itself.
    { "]g", function() require("grapple").cycle_tags "next" end, desc = "Next grapple tag" },
    { "[g", function() require("grapple").cycle_tags "prev" end, desc = "Previous grapple tag" },

    { "<Leader>1", function() require("grapple").select { index = 1 } end, desc = "Grapple tag 1" },
    { "<Leader>2", function() require("grapple").select { index = 2 } end, desc = "Grapple tag 2" },
    { "<Leader>3", function() require("grapple").select { index = 3 } end, desc = "Grapple tag 3" },
    { "<Leader>4", function() require("grapple").select { index = 4 } end, desc = "Grapple tag 4" },
  },
}
