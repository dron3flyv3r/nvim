local editor = require "lang.unity.editor"
local project = require "lang.unity.project"

local M = {}

local ADAPTER = "bin/UnityDebugAdapter.dll"

---@return string|nil
function M.extension_path()
  local best, best_version = nil, nil
  for _, root in ipairs {
    vim.fn.expand "~/.vscode/extensions",
    vim.fn.expand "~/.vscode-server/extensions",
    vim.fn.expand "~/.vscode-oss/extensions",
    vim.fn.expand "~/.vscode-insiders/extensions",
  } do
    for _, path in ipairs(vim.fn.glob(root .. "/visualstudiotoolsforunity.vstuc-*", false, true)) do
      -- The adapter itself, not just the directory: a half-removed extension
      -- leaves the folder behind.
      if vim.fn.filereadable(path .. "/" .. ADAPTER) == 1 then
        local version = vim.version.parse(vim.fs.basename(path):match "vstuc%-(.+)$" or "")
        if version and (not best_version or vim.version.gt(version, best_version)) then
          best, best_version = path, version
        end
      end
    end
  end
  return best
end

---@return string
function M.install_hint()
  return "Unity debugging needs Microsoft's Unity debug adapter, which ships in the VS Code extension.\n"
    .. "Install it once (VS Code itself is not needed afterwards):\n\n"
    .. "  code --install-extension visualstudiotoolsforunity.vstuc"
end

---@return boolean|string
function M.available()
  if vim.fn.executable "dotnet" ~= 1 then return "dotnet is not on PATH" end
  return M.extension_path() ~= nil or "The vstuc debug adapter is not installed"
end

--- nvim-dap's function form, so the four extension directories are globbed when
--- a session starts rather than on every start of an editor that is not
--- debugging Unity. Left uncalled when there is nothing to call it with: the
--- session does not begin, and the notification says why.
---@param callback fun(adapter: table)
function M.adapter(callback)
  local extension = M.extension_path()
  if not extension then
    vim.notify(M.install_hint(), vim.log.levels.ERROR, { title = "Unity" })
    return
  end
  callback { type = "executable", command = "dotnet", args = { extension .. "/" .. ADAPTER } }
end

---@param name string
---@param endpoint string
---@param source_root string
---@return table
function M.attach_config(name, endpoint, source_root)
  return {
    type = "vstuc",
    request = "attach",
    name = name,
    -- Where the adapter looks for the sources behind the line numbers Mono
    -- reports out of the .pdb files.
    projectPath = source_root,
    endPoint = endpoint,
    -- Off unless asked for: the adapter writes a verbose protocol trace here
    -- and never truncates it.
    logFile = vim.g.unity_dap_log or nil,
  }
end

--- One per running editor, the buffer's own project first so a project with a
--- single editor open needs no choice at all.
---@param bufnr integer
---@return table[]
function M.configurations(bufnr)
  local root = project.root(bufnr)
  if not root then return {} end

  local ours, others = {}, {}
  for _, instance in ipairs(editor.list()) do
    local config = M.attach_config(
      ("Unity: %s"):format(editor.describe(instance)),
      ("127.0.0.1:%d"):format(instance.debug_port),
      -- The editor's own project, for the case of attaching to a second one.
      instance.project or root
    )
    table.insert(instance.project == root and ours or others, config)
  end

  return vim.list_extend(ours, others)
end

function M.attach()
  local root = project.require_root()
  if not root then return end

  local why = M.available()
  if why ~= true then
    vim.notify(why == "dotnet is not on PATH" and why or M.install_hint(), vim.log.levels.ERROR, { title = "Unity" })
    return
  end

  local configs = M.configurations(0)
  if vim.tbl_isempty(configs) then
    vim.notify(
      "No Unity editor is running -- open the project in Unity first",
      vim.log.levels.WARN,
      { title = "Unity" }
    )
    return
  end

  local dap = require "dap"
  if #configs == 1 then return dap.run(configs[1]) end
  vim.ui.select(configs, {
    prompt = "Attach to which Unity?",
    format_item = function(config) return config.name end,
  }, function(config)
    if config then dap.run(config) end
  end)
end

return M
