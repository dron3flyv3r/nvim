local M = {}

local bufnr, win, width

local function panel_window()
  if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then return win end
end

local function leave()
  vim.cmd.stopinsert()
  vim.api.nvim_set_current_win(require("core.open").window())
end

local function hide()
  local panel = panel_window()
  if not panel then return end
  width = vim.api.nvim_win_get_width(panel)
  if panel == vim.api.nvim_get_current_win() and vim.fn.winnr "$" == 1 then leave() end
  vim.api.nvim_win_hide(panel)
  win = nil
end

local function exited(buf)
  if bufnr ~= buf then return end
  hide()
  bufnr = nil
  if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
end

local function dress(panel)
  local options = vim.wo[panel]
  options.number = false
  options.relativenumber = false
  options.signcolumn = "no"
  options.foldcolumn = "0"
  options.statuscolumn = ""
  options.wrap = false
  options.list = false
  options.winfixwidth = true
  options.winbar = " TUI panel  ·  Ctrl-Q returns to editor"
end

local function show(buf)
  -- The bottom strip's WinNew handler owns splits made from its windows.
  local ok, panel = pcall(vim.api.nvim_open_win, buf, false, {
    split = "right",
    win = -1,
    width = math.max(1, math.min(width or math.floor(vim.o.columns / 2), math.floor(vim.o.columns * 0.75))),
    noautocmd = true,
  })
  if not ok then
    vim.notify("Could not open the TUI panel: " .. panel, vim.log.levels.WARN)
    return false
  end
  win = panel
  dress(panel)
  vim.api.nvim_set_current_win(panel)
  return true
end

function M.toggle()
  local panel = panel_window()
  if panel then
    if vim.api.nvim_win_get_tabpage(panel) == vim.api.nvim_get_current_tabpage() then return hide() end
    vim.api.nvim_set_current_win(panel)
    vim.cmd.startinsert()
    return
  end

  local fresh = not bufnr or not vim.api.nvim_buf_is_valid(bufnr)
  local buf = not fresh and bufnr or vim.api.nvim_create_buf(false, true)
  if fresh then
    vim.b[buf].core_tui_panel = true
    vim.api.nvim_buf_set_name(buf, "tui://shell")
  end
  if not show(buf) then
    if fresh then vim.api.nvim_buf_delete(buf, { force = true }) end
    return
  end
  bufnr = buf

  if fresh then
    local cmd = require("core.terminal").shell_command(true)
    local job = vim.fn.jobstart(cmd, {
      term = true,
      cwd = vim.uv.cwd() or vim.fn.getcwd(),
      env = { NVIM_PANEL_NVIM = vim.v.progpath },
      on_exit = function() vim.schedule(function() exited(buf) end) end,
    })
    if job <= 0 then
      exited(buf)
      vim.notify("Could not start a shell in the TUI panel", vim.log.levels.ERROR)
      return
    end
    require("core.keymaps").forward_terminal(buf, leave, true)
  end
  vim.cmd.startinsert()
end

return M
