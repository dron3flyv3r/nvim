-- require("plugins.key-hints.control").enable()

local detach_path = vim.fs.normalize "~/code/detach.nvim"
if vim.uv.fs_stat(detach_path) then
  vim.opt.rtp:append(detach_path)
  local detach = require "detach"

  local fullscreen = vim.fs.normalize "~/.config/fish/functions/fullscreen.fish"
  detach.setup {
    wrap = vim.uv.fs_stat(fullscreen) and { "fish", "-c", "fullscreen $argv", "--" } or {},
    can_send = function(bufnr)
      local ok, review = pcall(require, "plugins.git.review")
      if ok and review.holds(bufnr) then return "A git review is holding this buffer; settle it with q first" end
      return true
    end,
  }

  if detach.is_side() then require("core.session").disable() end

  for _, key in ipairs { "h", "j", "k", "l" } do
    local move = function() detach.move(key) end
    vim.keymap.set("n", "<C-" .. key .. ">", move, { desc = "Window " .. key .. " or across screens" })
    vim.keymap.set(
      "t",
      "<C-" .. key .. ">",
      ("<C-\\><C-n><Cmd>lua require('detach').move('%s')<CR>"):format(key),
      { desc = "Window " .. key .. " or across screens" }
    )
    vim.keymap.set(
      "n",
      "<Leader>w" .. key:upper(),
      function() detach.send(key) end,
      { desc = "Send buffer to the instance " .. key }
    )
  end
  vim.keymap.set("n", "<Leader>wd", detach.detach, { desc = "Detach buffer to a new instance" })
  vim.keymap.set("n", "<Leader>wn", detach.spawn, { desc = "New linked instance" })
  vim.keymap.set("n", "<Leader>wa", detach.attach, { desc = "Send buffer back to the main instance" })
  vim.keymap.set("n", "<Leader>wi", detach.list, { desc = "Linked instances" })

  require("core.statusline").register("detach", {
    side = "right",
    order = -10,
    text = function() return detach.status() end,
  })
end
