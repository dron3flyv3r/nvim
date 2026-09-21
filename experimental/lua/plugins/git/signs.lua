local M = {}

---@param message string
---@param level? integer
local function say(message, level) vim.notify(message, level or vim.log.levels.WARN, { title = "Git" }) end

-- gitsigns builds the inline preview's float with `nvim_create_buf` and copies
-- only `filetype` onto it, but editorconfig sets indent width per file off
-- `BufReadPost`, which a scratch buffer never fires -- so every old line lands
-- `(file tabstop - ftplugin tabstop) * depth` columns off. `vartabstop`
-- overrides `tabstop` wherever it is set, so it has to travel too.
---@param src_win integer
---@param src_buf integer
---@return boolean found whether the float was up yet
local function align_preview_float(src_win, src_buf)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local cfg = vim.api.nvim_win_get_config(win)
    -- gitsigns anchors this float to the window it previewed, which is specific
    -- enough never to catch a notification or a which-key popup.
    if cfg.relative == "win" and cfg.win == src_win then
      local buf = vim.api.nvim_win_get_buf(win)
      vim.bo[buf].tabstop = vim.bo[src_buf].tabstop
      vim.bo[buf].vartabstop = vim.bo[src_buf].vartabstop
      return true
    end
  end
  return false
end

-- `preview_hunk_inline` is asynchronous and the float is 2-6ms behind it, so the
-- fixup waits on a millisecond timer. Not `vim.schedule`: scheduled callbacks
-- run on consecutive event-loop turns, so a chain of them is spent inside a
-- microsecond and gives up long before the float exists.
local function preview_inline()
  local src_win, src_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  require("gitsigns").preview_hunk_inline()
  local tries = 0
  local function wait_for_float()
    tries = tries + 1
    if not align_preview_float(src_win, src_buf) and tries < 25 then vim.defer_fn(wait_for_float, 10) end
  end
  wait_for_float()
end

---@param bufnr integer
---@param what string
---@return boolean
local function held(bufnr, what)
  local ok, review = pcall(require, "plugins.git.review")
  if not (ok and review.holds(bufnr)) then return false end
  say(
    ("This buffer is under review -- %s cannot take part in an in-memory transaction. Press q there first"):format(
      what
    )
  )
  return true
end

---@param fn string a gitsigns function name
---@param what string
---@return fun()
local function index(fn, what)
  return function()
    if held(vim.api.nvim_get_current_buf(), what) then return end
    require("gitsigns")[fn]()
  end
end

---@param fn string
---@param what string
---@return fun()
local function index_range(fn, what)
  return function()
    if held(vim.api.nvim_get_current_buf(), what) then return end
    require("gitsigns")[fn] { vim.fn.line ".", vim.fn.line "v" }
  end
end

---@param reverse boolean
---@return fun()
local function nav(reverse)
  return function()
    -- In a real diff the native motion is the right one, and gitsigns has no
    -- hunks of its own to walk there.
    if vim.wo.diff then return vim.cmd.normal { reverse and "[c" or "]c", bang = true } end
    require("gitsigns").nav_hunk(reverse and "prev" or "next")
  end
end

---@param bufnr integer
function M.on_attach(bufnr)
  ---@param mode string|string[]
  ---@param lhs string
  ---@param rhs function
  ---@param desc string
  local function map(mode, lhs, rhs, desc)
    vim.keymap.set(mode, lhs, rhs, { buffer = bufnr, desc = desc })
  end

  map("n", "]g", nav(false), "Next git hunk")
  map("n", "[g", nav(true), "Previous git hunk")

  map("n", "<Leader>gp", preview_inline, "Preview this hunk inline")
  map("n", "<Leader>gP", function() require("gitsigns").preview_hunk() end, "Preview this hunk in a popup")

  map("n", "<Leader>gr", index("reset_hunk", "resetting a hunk"), "Reset this hunk")
  map("x", "<Leader>gr", index_range("reset_hunk", "resetting lines"), "Reset the selected lines")
  map("n", "<Leader>gR", index("reset_buffer", "resetting the file"), "Reset the whole file")
  map("n", "<Leader>gs", index("stage_hunk", "staging"), "Stage this hunk")
  map("x", "<Leader>gs", index_range("stage_hunk", "staging"), "Stage the selected lines")
  map("n", "<Leader>gS", index("stage_buffer", "staging"), "Stage the whole file")
  map("n", "<Leader>gu", index("undo_stage_hunk", "unstaging"), "Undo the last stage")

  map("n", "<Leader>gb", function() require("gitsigns").toggle_current_line_blame() end, "Toggle current-line blame")
  map("n", "<Leader>gB", function() require("gitsigns").blame_line { full = true } end, "Full blame for this line")
end

-- Diffview deletes every buffer-local keymap it set when it detaches a file, and
-- two of them -- `<Leader>gr` and `<Leader>gR` -- are keys gitsigns had already
-- put there. Without re-applying them, resetting a hunk in a file you have
-- reviewed once does nothing for the rest of the session.
function M.remap()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.b[buf].gitsigns_status_dict ~= nil then M.on_attach(buf) end
  end
end

---@return table
function M.opts()
  return {
    signs = {
      add = { text = "▎" },
      change = { text = "▎" },
      delete = { text = "" },
      topdelete = { text = "" },
      changedelete = { text = "▎" },
      untracked = { text = "┆" },
    },
    signs_staged_enable = true,
    attach_to_untracked = true,
    preview_config = { border = "rounded" },
    current_line_blame_opts = { delay = 300, virt_text_pos = "eol" },
    on_attach = M.on_attach,
  }
end

return M
