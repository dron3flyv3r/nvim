-- Debugging C# running inside Unity, with breakpoints, stepping and variable
-- inspection in the editor process itself.
--
-- WHAT THE ADAPTER IS. Unity runs Mono, not CoreCLR, so `netcoredbg` and
-- `vsdbg` -- the adapters the rest of the .NET world uses -- cannot attach to
-- it. What can is the Mono soft debugger, and the DAP front end for it that
-- Microsoft ships inside the Visual Studio Tools for Unity extension for VS
-- Code: `UnityDebugAdapter.dll`. It is a plain stdio DAP server (verified: it
-- answers `initialize` with no arguments and no `--` flags), so nvim-dap can
-- drive it directly.
--
-- We borrow it from the VS Code extension directory rather than vendoring it,
-- because it is a 40 MB tree of signed Microsoft assemblies that has to stay in
-- step with the Unity versions it supports. If the extension is not installed,
-- `M.setup` says so once and registers nothing -- see `M.install_hint`.
--
-- THE ONLY CONFIGURATION THAT MATTERS is `attach`, with an `endPoint` of
-- `127.0.0.1:<port>`. There is no `launch`: you do not start Unity under the
-- debugger, you attach to the editor that is already open. `user.unity_editor`
-- works out the port.
--
-- WHY A CONFIG *PROVIDER* AND NOT `dap.configurations.cs`. A static
-- configuration would have to name a port, and the port changes every time
-- Unity restarts (it is derived from the pid). nvim-dap's `providers.configs`
-- hook runs at `dap.continue()` time and can return a freshly built list, so
-- the ports are always current -- and when two editors are open you get one
-- entry per editor in nvim-dap's own picker rather than a custom prompt.
--
-- HOW TO USE IT: open Unity, put the cursor on a line inside a MonoBehaviour,
-- `<Leader>db` to breakpoint it, `<Leader>dc` to attach, then press Play in
-- Unity through the contextual menu. AstroNvim still owns the native
-- `<Leader>d` debugger keys.

local M = {}

--- Where VS Code keeps the Unity extension.
---
--- Sorted by parsed version rather than by name so that 1.10.0 beats 1.9.0 --
--- lexical sorting gets that backwards, and the extension directory keeps every
--- version it has ever installed until VS Code prunes it.
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
  -- Last resort: a copy left behind by `nvim-dap-unity`, which downloads the
  -- same .vsix itself. There is one at
  -- `~/.local/share/nvim/nvim-dap-unity/vstuc/content/extension` on this
  -- machine from an earlier attempt at this; no version in the path, so it
  -- only gets a look in when VS Code has nothing.
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
    -- The adapter answers `initialize` with
    -- `supportsConfigurationDoneRequest: false`, so nvim-dap must not wait for
    -- a `configurationDone` round trip it will never get. nvim-dap reads that
    -- from the capabilities itself -- noted here because a hand-written
    -- adapter definition is where people usually add `options` to fix it.
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
