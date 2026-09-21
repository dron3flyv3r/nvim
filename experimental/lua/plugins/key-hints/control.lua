local M = {}

local MODES = { "n", "x", "s", "o" }
local enabled = false
local ready = false
local previous_timeoutlen

local function refresh()
  if not ready then return end

  local config = require "which-key.config"
  for _, mode in ipairs(MODES) do
    config.triggers.modes[mode] = enabled or nil
  end

  require("which-key.state").stop()
  local buffers = require "which-key.buf"
  buffers.clear()
  if enabled then
    for _, mode in ipairs(MODES) do
      buffers.get { mode = mode }
    end
  end

  if enabled then
    previous_timeoutlen = previous_timeoutlen or vim.o.timeoutlen
    vim.o.timeoutlen = 300
  elseif previous_timeoutlen then
    vim.o.timeoutlen = previous_timeoutlen
    previous_timeoutlen = nil
  end
end

---@param value boolean
---@param notify? boolean
local function set(value, notify)
  enabled = value
  if not package.loaded["which-key"] then require("lazy").load { plugins = { "which-key.nvim" } } end
  refresh()
  if notify then vim.notify("Key hints " .. (enabled and "enabled" or "disabled")) end
end

function M.enable() set(true) end

function M.disable() set(false) end

function M.toggle() set(not enabled, true) end

---@return boolean
function M.enabled() return enabled end

function M.setup()
  require("which-key").setup {
    preset = "modern",
    delay = 300,
    triggers = {},
    filter = function(mapping) return mapping.desc ~= nil and mapping.desc ~= "" end,
    plugins = {
      marks = false,
      registers = false,
      spelling = { enabled = false },
    },
    win = { border = "rounded" },
    spec = {
      { "<Leader>b", group = "Buffer" },
      { "<Leader>d", group = "Debug" },
      { "<Leader>f", group = "Find" },
      { "<Leader>s", group = "Search" },
      { "<Leader>u", group = "Toggle" },
      { "<Leader>w", group = "Window" },
    },
  }

  local function finish()
    if not require("which-key.config").loaded then
      vim.defer_fn(finish, 10)
      return
    end
    ready = true
    refresh()
  end
  finish()
end

return M
