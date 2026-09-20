local M = {}

local PANEL = 1
local PANEL_WIDTH = 55

--- Four stacked panes need a full-height terminal and the code beside them still
--- has to be readable. Under this the panel is never built and its elements are
--- reached as floats instead.
local MIN_COLUMNS = 150

--- Sizes are re-applied by hand after opening, so they live here rather than
--- inline in the layout.
local PANEL_ELEMENTS = {
  { id = "breakpoints", size = 0.15 },
  { id = "stacks", size = 0.20 },
  { id = "scopes", size = 0.40 },
  { id = "watches", size = 0.25 },
}

local FLOATS = {
  breakpoints = { width = 100, height = 20 },
  stacks = { width = 100, height = 20 },
  scopes = { width = 100, height = 25 },
  watches = { width = 80, height = 12 },
}

local REPL = "repl"
local PROGRAM = "program"

--- Whether this terminal was wide enough for a panel when the layout was built.
--- `dapui.setup` tears down every window it owns, so it cannot be rebuilt on a
--- resize and the decision is made once.
local panelled = false
local open = false

---@return boolean
local function roomy() return vim.o.columns >= MIN_COLUMNS end

--- Give the panel's panes the heights they were configured with.
---
--- dap-ui asks for them itself and gets them wrong: `WindowLayout:resize` walks
--- its windows with `pairs`, so a vertical stack is sized in whatever order the
--- table yields and each pane takes space from a neighbour that may not have been
--- sized yet. Four panes come out as roughly one. Setting them bottom upwards is
--- deterministic: each takes from the one above, and the top absorbs the
--- rounding.
local function size_panel()
  local layout = require("dapui.windows").layouts[PANEL]
  if not layout or not layout:is_open() then return end

  local wins = layout.opened_wins
  if #wins ~= #PANEL_ELEMENTS then return end

  local total = 0
  for _, win in ipairs(wins) do
    total = total + vim.api.nvim_win_get_height(win)
  end
  for i = #wins, 2, -1 do
    pcall(vim.api.nvim_win_set_height, wins[i], math.max(1, math.floor(PANEL_ELEMENTS[i].size * total)))
  end
end

---@param id string
function M.float(id)
  local size = FLOATS[id] or { width = 100, height = 20 }
  require("dapui").float_element(id, {
    enter = true,
    position = "center",
    width = size.width,
    height = size.height,
  })
end

function M.panel_open() return open end

function M.open()
  if not panelled or open then return end
  require("dapui").open { layout = PANEL }
  open = true
  size_panel()
end

function M.close()
  if not open then return end
  require("dapui").close { layout = PANEL }
  open = false
end

--- `<Leader>du`. On a terminal too narrow for a panel this is the scopes float,
--- which is the pane the panel exists for.
function M.toggle()
  if open then return M.close() end
  if not panelled then return M.float "scopes" end
  M.open()
end

--- The REPL is a tenant of the shared bottom strip rather than a window of its
--- own: `new_win` sets the buffer into whatever window the wincmd leaves current.
function M.repl()
  local pane = require "core.pane"
  local dap = require "dap"

  dap.repl.open(nil, [[lua vim.api.nvim_set_current_win(require("core.pane").window())]])
  local win = pane.window()
  pane.show({
    name = REPL,
    bufnr = vim.api.nvim_win_get_buf(win),
    close = function()
      dap.repl.close()
      pane.release(REPL)
    end,
  }, { enter = true, insert = true })
end

--- Where the debugged program's own stdout goes. codelldb asks for an integrated
--- terminal through `runInTerminal`, and nvim-dap's default answer is
--- `belowright new` -- a window nothing here manages, which is how the output went
--- missing. This hands it a buffer in the strip instead.
---@return integer bufnr
---@return integer winid
local function program_buffer()
  local bufnr = vim.api.nvim_create_buf(false, true)
  local win = require("core.pane").show { name = PROGRAM, bufnr = bufnr }
  return bufnr, assert(win)
end

--- nvim-dap pools terminal buffers and reuses one without asking for a window
--- again, so a second run has to be re-adopted. `jobstart` fires TermOpen either
--- way, and `dap-type` is what nvim-dap marks its own terminals with.
local function adopt_program_terminals()
  vim.api.nvim_create_autocmd("TermOpen", {
    group = vim.api.nvim_create_augroup("plugins_debug_program", { clear = true }),
    callback = function(args)
      if vim.b[args.buf]["dap-type"] == nil then return end
      require("core.pane").show { name = PROGRAM, bufnr = args.buf }
    end,
  })
end

---@return boolean shown
function M.program() return require("core.pane").focus(PROGRAM, { enter = true }) ~= nil end

function M.hide_repl()
  pcall(function() require("dap").repl.close() end)
  require("core.pane").release(REPL)
end

--- The DAP spec makes `result` required on an `evaluate` response, and adapters
--- send hovers without one anyway; `format_value` then splits a nil inside an nio
--- task with no error handler and the float comes up holding a traceback.
local function harden_values()
  local util = require "dapui.util"
  if util.core_nil_value_guard then return end
  util.core_nil_value_guard = true

  local format_value = util.format_value
  function util.format_value(value_start, value) return format_value(value_start, value or "<unavailable>") end
end

function M.setup()
  local dapui = require "dapui"

  local dap = require "dap"
  dap.defaults.fallback.terminal_win_cmd = program_buffer
  dap.defaults.fallback.focus_terminal = false
  adopt_program_terminals()

  panelled = roomy()
  dapui.setup {
    layouts = { { position = "left", size = PANEL_WIDTH, elements = PANEL_ELEMENTS } },
    floating = { border = "rounded", mappings = { close = { "q", "<Esc>" } } },
    controls = { enabled = false },
    icons = { expanded = "▾", collapsed = "▸", current_frame = "▸" },
    mappings = { expand = { "<CR>", "<Tab>" }, open = "o", remove = "d", edit = "e", repl = "r", toggle = "t" },
  }
  harden_values()
end

return M
