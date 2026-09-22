local M = {}

local REGISTERS = "abcdefghijklmnopqrstuvwxyz"
local MAX_KEYS = 120

---@type table<string, integer>
local recorded = {}
local order = 0

---@return string?
function M.recording()
  local register = vim.fn.reg_recording()
  return register ~= "" and register or nil
end

---@param register string
function M.remember(register)
  if register == "" then return end
  order = order + 1
  recorded[register:lower()] = order
end

---@class core.macros.Entry
---@field register string
---@field keys string
---@field session boolean recorded during this session rather than restored from shada

---@return core.macros.Entry[]
function M.list()
  local entries = {}
  for register in REGISTERS:gmatch "." do
    local content = vim.fn.getreg(register)
    if content ~= "" then
      entries[#entries + 1] = {
        register = register,
        keys = vim.fn.keytrans(content),
        session = recorded[register] ~= nil,
      }
    end
  end
  table.sort(entries, function(a, b)
    local a_order, b_order = recorded[a.register] or 0, recorded[b.register] or 0
    if a_order ~= b_order then return a_order > b_order end
    return a.register < b.register
  end)
  return entries
end

---@param entry core.macros.Entry
---@return string
local function format(entry)
  local keys = entry.keys
  if vim.fn.strcharlen(keys) > MAX_KEYS then keys = vim.fn.strcharpart(keys, 0, MAX_KEYS - 1) .. "…" end
  return ("%s @%s  %s"):format(entry.session and "●" or " ", entry.register, keys)
end

function M.pick()
  local entries = M.list()
  if #entries == 0 then
    vim.notify("No register holds a macro", vim.log.levels.INFO, { title = "Macros" })
    return
  end
  vim.ui.select(entries, { prompt = "Macros", format_item = format }, function(entry)
    if entry then vim.schedule(function() vim.cmd.normal { "@" .. entry.register, bang = true } end) end
  end)
end

function M.setup()
  vim.api.nvim_create_user_command("Macros", M.pick, { desc = "List the macro registers and run one" })
end

return M
