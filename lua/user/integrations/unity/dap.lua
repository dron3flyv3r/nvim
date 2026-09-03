local M = {}

---@return string|nil path
function M.extension_path()
  local roots = {
    vim.fn.expand "~/.vscode/extensions",
    vim.fn.expand "~/.vscode-server/extensions",
    vim.fn.expand "~/.vscode-oss/extensions",
    vim.fn.expand "~/.vscode-insiders/extensions",
  }

  local best, best_version = nil, nil
  for _, root in ipairs(roots) do
    for _, path in ipairs(vim.fn.glob(root .. "/visualstudiotoolsforunity.vstuc-*", false, true)) do
      -- The adapter, not just the directory: a half-removed extension leaves
      -- the folder behind.
      if vim.fn.filereadable(path .. "/bin/UnityDebugAdapter.dll") == 1 then
        local version = vim.version.parse(vim.fs.basename(path):match "vstuc%-(.+)$" or "")
        if version and (not best_version or vim.version.gt(version, best_version)) then
          best, best_version = path, version
        end
      end
    end
  end
  if not best then
    local standalone = vim.fn.expand "~/.local/share/nvim/nvim-dap-unity/vstuc/content/extension"
    if vim.fn.filereadable(standalone .. "/bin/UnityDebugAdapter.dll") == 1 then return standalone end
  end

  return best
end

--- What to tell someone who has not installed the extension.
---@return string
function M.install_hint()
  return "Unity debugging needs Microsoft's Unity debug adapter, which ships in the VS Code extension.\n"
    .. "Install it once (VS Code itself is not needed afterwards):\n\n"
    .. "  code --install-extension visualstudiotoolsforunity.vstuc\n\n"
    .. "or download the .vsix from the marketplace and unzip it into\n"
    .. "  ~/.vscode/extensions/visualstudiotoolsforunity.vstuc-<version>/"
end

--- The attach configurations available for `bufnr` right now: one per running
--- editor, the project's own editor first.
---@param bufnr integer
---@return table[]
function M.configurations(bufnr)
  local unity = require "user.integrations.unity"
  local root = unity.root(bufnr)
  if not root then return {} end

  local editors = require "user.integrations.unity.editor"
  local configs = {}
  for _, instance in ipairs(editors.list()) do
    local mine = instance.project == root
    table.insert(configs, {
      -- `mine` first, so `dap.continue()` on a project with one editor open
      -- needs no choice at all and everything else is still reachable.
      order = mine and 1 or 2,
      config = {
        type = "vstuc",
        request = "attach",
        name = ("Unity: %s"):format(editors.describe(instance)),
        -- Where the adapter looks for the sources behind the .pdb line
        -- numbers Mono reports. The editor's own project, not ours, for the
        -- case where you are attaching to a second project's editor.
        projectPath = instance.project or root,
        endPoint = ("127.0.0.1:%d"):format(instance.debug_port),
        -- Off unless asked for: the adapter writes a verbose protocol trace
        -- here and never truncates it.
        logFile = vim.g.unity_dap_log or nil,
      },
    })
  end

  table.sort(configs, function(a, b) return a.order < b.order end)
  return vim.tbl_map(function(entry) return entry.config end, configs)
end

--- Register the adapter and the config provider. Idempotent.
---@return boolean ok
function M.setup()
  local extension = M.extension_path()
  if not extension then return false end

  local dap = require "dap"

  dap.adapters.vstuc = {
    type = "executable",
    command = "dotnet",
    args = { extension .. "/bin/UnityDebugAdapter.dll" },
  }

  -- A named provider, so re-running `setup` replaces it instead of stacking.
  dap.providers.configs["user.unity"] = function(bufnr) return M.configurations(bufnr) end

  return true
end

--- Attach to Unity, or explain why not. This is the contextual debug action.
function M.attach()
  local root = require("user.integrations.unity").require_root()
  if not root then return end

  if not M.extension_path() then
    vim.notify(M.install_hint(), vim.log.levels.ERROR, { title = "Unity" })
    return
  end
  M.setup()

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
  if #configs == 1 then
    dap.run(configs[1])
    return
  end
  vim.ui.select(configs, {
    prompt = "Attach to which Unity?",
    format_item = function(config) return config.name end,
  }, function(config)
    if config then dap.run(config) end
  end)
end

return M
