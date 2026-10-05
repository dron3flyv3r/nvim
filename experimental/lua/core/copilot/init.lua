local M = {}

M.SERVER = "copilot"
M.BINARY = "copilot-language-server"

local EXCLUDED_FILETYPES = { gitcommit = true, gitrebase = true, NeogitCommitMessage = true }

local active = false
local enabled = true

---@type table<string, true>
local suspensions = {}

local function notify(message, level) vim.notify(message, level or vim.log.levels.INFO, { title = "Copilot" }) end

---@param bufnr integer
---@return boolean
local function excluded(bufnr)
  if EXCLUDED_FILETYPES[vim.bo[bufnr].filetype] then return true end
  return vim.fs.basename(vim.api.nvim_buf_get_name(bufnr)):match "^%.env" ~= nil
end

local function apply()
  if active then vim.lsp.inline_completion.enable(M.is_enabled()) end
end

---@return boolean
function M.active() return active end

---@return boolean
function M.is_enabled() return active and enabled and next(suspensions) == nil end

---@param state boolean
function M.set(state)
  if not active then
    notify("Copilot is not enabled on this device; see lua/user", vim.log.levels.WARN)
    return
  end
  enabled = state
  suspensions = {}
  apply()
end

---@param reason string
function M.suspend(reason)
  suspensions[reason] = true
  apply()
end

---@param reason string
function M.resume(reason)
  suspensions[reason] = nil
  apply()
end

---@return boolean
function M.accept() return M.is_enabled() and vim.lsp.inline_completion.get() end

---@param bufnr? integer
---@return vim.lsp.Client?
function M.client(bufnr) return vim.lsp.get_clients({ name = M.SERVER, bufnr = bufnr })[1] end

---@param client vim.lsp.Client
---@param bufnr integer
---@param result table
local function finish_device_flow(client, bufnr, result)
  vim.fn.setreg("+", result.userCode)
  notify(("Code %s is on the clipboard; paste it at %s"):format(result.userCode, result.verificationUri))
  vim.ui.open(result.verificationUri)
  client:exec_cmd(result.command, { bufnr = bufnr }, function(err, status)
    if err or not status or status.status ~= "OK" then
      notify("Sign-in failed: " .. (err and err.message or vim.inspect(status)), vim.log.levels.ERROR)
    else
      notify("Signed in as " .. status.user)
    end
  end)
end

---@param bufnr integer
function M.sign_in(bufnr)
  local client = M.client(bufnr)
  if not client then return end
  client:request("signIn", vim.empty_dict(), function(err, result)
    if err then
      notify("Sign-in failed: " .. err.message, vim.log.levels.ERROR)
    elseif result.status == "AlreadySignedIn" then
      notify("Already signed in as " .. result.user)
    else
      finish_device_flow(client, bufnr, result)
    end
  end, bufnr)
end

---@param bufnr integer
function M.sign_out(bufnr)
  local client = M.client(bufnr)
  if not client then return end
  client:request("signOut", vim.empty_dict(), function(err)
    if err then
      notify("Sign-out failed: " .. err.message, vim.log.levels.ERROR)
    else
      notify "Signed out"
    end
  end, bufnr)
end

---@param ctx core.Context
---@return boolean|string
local function attached(ctx)
  if M.client(ctx.bufnr) then return true end
  if excluded(ctx.bufnr) then return "Copilot is kept out of this filetype" end
  return "copilot-language-server is not attached to this buffer"
end

local provider = {
  id = "copilot",
  name = "Copilot",
  priority = -10,
  detect = function() return active end,
  actions = function()
    return {
      {
        id = "sign_in",
        label = "Sign in to GitHub Copilot",
        category = "Maintenance",
        repeatable = false,
        available = attached,
        run = function(ctx) M.sign_in(ctx.bufnr) end,
      },
      {
        id = "sign_out",
        label = "Sign out of GitHub Copilot",
        category = "Maintenance",
        repeatable = false,
        available = attached,
        run = function(ctx) M.sign_out(ctx.bufnr) end,
      },
    }
  end,
  status = function(ctx)
    return { ("suggestions %s, server %s"):format(
      M.is_enabled() and "on" or "off",
      M.client(ctx.bufnr) and "attached" or "not attached"
    ) }
  end,
}

---@type table<string, true>
local reported = {}

local function on_status(_, params)
  if params.kind ~= "Error" and params.kind ~= "Warning" then return end
  if not params.message or reported[params.message] then return end
  reported[params.message] = true
  notify(params.message, params.kind == "Error" and vim.log.levels.ERROR or vim.log.levels.WARN)
end

---@class core.copilot.Opts
---@field node? string a Node.js new enough for the server when the one on PATH is not

---@param opts? core.copilot.Opts
function M.enable(opts)
  opts = opts or {}
  if active then return end
  if vim.fn.executable(M.BINARY) ~= 1 then
    notify(M.BINARY .. " is not on PATH; install it with :MasonInstall " .. M.BINARY, vim.log.levels.WARN)
    return
  end
  active = true
  M.node = opts.node

  local cmd = { M.BINARY, "--stdio" }
  if opts.node then cmd = { opts.node, vim.fn.exepath(M.BINARY), "--stdio" } end

  local version = tostring(vim.version())
  vim.lsp.config(M.SERVER, {
    cmd = cmd,
    root_dir = function(bufnr, on_dir)
      if excluded(bufnr) then return end
      on_dir(vim.fs.root(bufnr, ".git") or vim.fn.getcwd())
    end,
    init_options = {
      editorInfo = { name = "Neovim", version = version },
      editorPluginInfo = { name = "Neovim", version = version },
    },
    handlers = { didChangeStatus = on_status },
  })
  vim.lsp.enable(M.SERVER)
  require("core.actions").register(provider)
  apply()
end

return M
