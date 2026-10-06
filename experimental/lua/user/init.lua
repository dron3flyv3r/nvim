-- require("plugins.key-hints.control").enable()

local function nvm_node(min_major)
  local found, best = nil, -1
  for _, dir in ipairs(vim.fn.glob(vim.fs.normalize "~/.nvm/versions/node/v*", false, true)) do
    local major = tonumber(vim.fs.basename(dir):match "^v(%d+)")
    if major and major >= min_major and major > best then
      found, best = dir .. "/bin/node", major
    end
  end
  return found
end

-- The system node is 20; copilot-language-server refuses anything below 22.13.
require("core.copilot").enable { node = nvm_node(22) }

require("plugins.code-analysis.control").enable {
  url = vim.env.SONAR_HOST_URL,
  projects = {
    ["/home/smally-work/git/display_master"] = "display"
  },
}

local explorer_exclude = { "*.meta", "*.uid", "*.prefab", "*.imports" }

local sources = require("snacks").config.picker.sources
sources.explorer = vim.tbl_extend("force", sources.explorer or {}, { exclude = explorer_exclude })

if vim.fn.executable "fish" == 1 then require("core.terminal").set_shell { "fish" } end

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
      "<Leader>W" .. key:upper(),
      function() detach.send(key) end,
      { desc = "Send buffer to the instance " .. key }
    )
  end
  vim.keymap.set("n", "<Leader>Wd", detach.detach, { desc = "Detach buffer to a new instance" })
  vim.keymap.set("n", "<Leader>Wn", detach.spawn, { desc = "New linked instance" })
  vim.keymap.set("n", "<Leader>Wa", detach.attach, { desc = "Send buffer back to the main instance" })
  vim.keymap.set("n", "<Leader>Wi", detach.list, { desc = "Linked instances" })

  require("core.statusline").register("detach", {
    side = "right",
    order = -10,
    text = function() return detach.status() end,
  })
end
