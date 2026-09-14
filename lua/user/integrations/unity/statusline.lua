local M = {}

--- How fast the spinner turns while Unity is busy. Only runs while it is.
local FRAME_MS = 80

--- What each state looks like. Highlight *groups* rather than palette colours,
--- so this follows the colourscheme without knowing which one is loaded.
local STATES = {
  playing = { icon = "󰐊", label = "Play", hl = "DiagnosticOk" },
  paused = { icon = "󰏤", label = "Paused", hl = "DiagnosticWarn" },
  compiling = { spin = true, label = "Compiling", hl = "DiagnosticWarn" },
  importing = { spin = true, label = "Importing", hl = "DiagnosticHint" },
  building = { spin = true, label = "Building", hl = "DiagnosticInfo" },
  idle = { icon = "󰝤", label = "Unity", hl = "Comment" },
  unknown = { icon = "󰝦", label = "Unity", hl = "Comment" },
}

--- The braille frames `astroui` already defines for the LSP spinner, so this
--- turns in step with the one next to it rather than to its own beat.
local FRAMES = require("astroui").get_spinner "LSPLoading" or { "-", "\\", "|", "/" }

local frame = 1
local timer ---@type uv.uv_timer_t|nil

--- Turn the spinner only while something is spinning. A statusline that redraws
--- twelve times a second forever is a laptop that runs warm for no reason.
---@param spinning boolean
local function animate(spinning)
  if spinning then
    if timer then return end
    timer = assert(vim.uv.new_timer())
    timer:start(
      FRAME_MS,
      FRAME_MS,
      vim.schedule_wrap(function()
        frame = frame % #FRAMES + 1
        vim.cmd.redrawstatus()
      end)
    )
  elseif timer then
    timer:stop()
    if not timer:is_closing() then timer:close() end
    timer = nil
  end
end

--- The statusline text: the editor's state, then the error count if the last
--- compile left one. Reads nothing off disk.
---@return string
function M.text()
  local state = require("user.integrations.unity.state").get()
  if not state.root then return "" end

  local out
  if not state.running then
    out = "󰝦 Unity off"
  else
    local look = STATES[state.state] or STATES.unknown
    out = ("%s %s"):format(look.spin and FRAMES[frame] or look.icon, look.label)
  end

  if state.errors > 0 then
    out = ("%s  %d"):format(out, state.errors)
  elseif state.warnings > 0 then
    out = ("%s  %d"):format(out, state.warnings)
  end
  return out
end

---@return string
local function highlight()
  local state = require("user.integrations.unity.state").get()
  if state.errors > 0 then return "DiagnosticError" end
  if not state.running then return "Comment" end
  return (STATES[state.state] or STATES.unknown).hl
end

--- The heirline component. No `update` key on purpose: the provider only reads
--- a table that is already in memory, so letting it run on every redraw is
--- cheaper than the bookkeeping that would avoid it -- and it means the spinner
--- needs nothing but `redrawstatus`.
---@return table
function M.component()
  return {
    condition = function()
      -- The state belongs to the editor, not to the buffer, but the statusline
      -- does belong to the buffer: a window on a file outside the project has
      -- no business reporting that project's play mode. `root` is cached per
      -- directory, so this is a table lookup on all but the first call.
      local root = require("user.integrations.unity.state").get().root
      return root ~= nil and require("user.integrations.unity").root(0) == root
    end,
    provider = function() return " " .. M.text() .. " " end,
    hl = function() return highlight() end,
    on_click = {
      name = "unity_status_click",
      callback = function()
        local state = require("user.integrations.unity.state").get()
        if state.errors > 0 or state.warnings > 0 then
          require("user.integrations.unity.log").errors(state.errors == 0)
        else
          require("user.integrations.unity.shim").status()
        end
      end,
    },
  }
end

function M.setup()
  vim.api.nvim_create_autocmd("User", {
    pattern = "UnityState",
    group = vim.api.nvim_create_augroup("unity_statusline", { clear = true }),
    desc = "Start and stop the Unity statusline spinner",
    callback = function()
      local state = require("user.integrations.unity.state").get()
      animate(state.running and (STATES[state.state] or {}).spin == true)
      vim.cmd.redrawstatus()
    end,
  })
end

return M
