-- Making Unity treat Neovim as its external script editor.
--
-- WHY THIS EXISTS. Two of the best things about Unity + an IDE are gated behind
-- one check in `com.unity.ide.visualstudio`:
--
--     if (!VisualStudioEditor.IsEnabled) return;      // VisualStudioIntegration.cs
--
-- Fail it and Unity does not bind its UDP control socket, so Play / Pause /
-- Refresh / run-tests from the editor are simply not available (see
-- `user.unity_messenger`), *and* project generation falls to whichever other
-- IDE package is installed -- Rider's, here, which emits legacy-format `.csproj`
-- files that a language server has to guess its way through.
--
-- Pass it and you get three things at once:
--
--   1. the control socket, so `<Leader>Up` really does press Play;
--   2. SDK-style `.csproj` files (`SdkStyleProjectGeneration`), which is the
--      format `roslyn_ls` is actually developed against;
--   3. Microsoft's Unity analyzers wired into those csproj files
--      (`VisualStudioCodeInstallation.GetAnalyzers()` reads them out of the
--      vstuc extension), which is where diagnostics like "UNT0001: Empty Unity
--      message" and their code fixes come from. Nothing else in Neovim's C#
--      stack provides Unity-aware lints.
--
-- HOW THE CHECK IS PASSED. `IsEnabled` is
-- `CodeEditor.CurrentEditor is VisualStudioEditor`, resolved by asking the VS
-- package whether it recognises the path in Unity's External Script Editor
-- preference. On Linux that test is, in full
-- (`VisualStudioCodeInstallation.IsCandidateForDiscovery`):
--
--     return File.Exists(path) && path.EndsWith("code", StringComparison.OrdinalIgnoreCase);
--
-- A file whose name is `code`. That is the entire contract -- Unity never runs
-- it to verify anything, it only executes it when you double-click a script.
-- So we install an executable called `code` that forwards to Neovim, and point
-- Unity at it.
--
-- This is a shim, not a lie with consequences: the only thing Unity ever asks
-- the "editor" to do is `code "<project dir>" -g "<file>":<line>:<column>`
-- (`VisualStudioCodeInstallation.Open`), which is exactly what the script
-- below implements.
--
-- WHAT ELSE CHANGES IN THE PROJECT. Switching the external editor makes the VS
-- package the project generator, which means:
--
--   * the `.csproj` / `.sln` files are rewritten in SDK style the next time
--     Unity syncs. They are generated files -- Unity's own `.gitignore`
--     template ignores them -- but if a teammate has committed them, this will
--     show up as a diff.
--   * a `.vscode/` directory appears with `settings.json`, `launch.json` and
--     `extensions.json` (`CreateExtraFiles`). Dropping an empty file at
--     `.vscode/.vstupatchdisable` stops Unity rewriting them.
--
-- Neither is reversible-by-accident: switching External Script Editor back to
-- Rider restores Rider's generator on the next sync.
--
-- HOW THE SHIM FINDS *THIS* NEOVIM. Every Neovim that enters a Unity project
-- starts listening on a socket named after that project
-- (`sha256(root)` truncated, because a Unix socket path has ~108 bytes to play
-- with and project paths are longer than that). The shim hashes the project
-- directory Unity handed it the same way and sends the open request there, so
-- double-clicking a script in Unity lands in the Neovim you already have that
-- project open in -- not a new one.

local M = {}

--- Roots this session has already tried to claim the socket for. The value is
--- whether we won it; the point is that a second attempt is never made.
---@type table<string, boolean>
local registered = {}

--- Where the fake `code` lives. Not on `$PATH` on purpose: nothing should pick
--- this up by accident, and Unity is given the absolute path.
M.shim = vim.fn.expand "~/.local/share/nvim-unity/bin/code"

--- Per-project socket for open-in-this-Neovim requests.
---@param root string
---@return string
function M.socket_path(root)
  local dir = (vim.env.XDG_RUNTIME_DIR or "/tmp") .. "/nvim-unity"
  vim.fn.mkdir(dir, "p")
  return ("%s/%s.sock"):format(dir, vim.fn.sha256(root):sub(1, 16))
end

--- Start listening for this project's open requests.
---
--- Two Neovims in one project is fine and not an error: the first one to get
--- here owns the socket and receives Unity's double-clicks, the others carry on
--- without it. Everything else in the Unity support works either way -- this
--- socket is only for the Unity -> Neovim direction.
---@param root string
---@return boolean listening
function M.register(root)
  -- ONCE PER ROOT, NOT ONCE PER BUFFER. The caller is a `BufReadPost` autocmd,
  -- so without this latch every file opened in a Unity project pays for a
  -- `stat`, an RPC connect to the socket and a channel teardown. Cheap on its
  -- own, silly in a loop, and it churns channel ids for nothing.
  if registered[root] ~= nil then return registered[root] end

  -- `--remote-expr` evaluates *Vimscript*, so the shim needs a global Vim
  -- function to call -- a `lua require(...)` string is not an expression.
  -- Defined here rather than at file scope so that a session which never opens
  -- a Unity project never defines it.
  if vim.fn.exists "*UnityOpenFromEditor" == 0 then
    vim.cmd [[
      function! UnityOpenFromEditor(payload) abort
        return luaeval('require("user.unity_shim").open(_A)', a:payload)
      endfunction
    ]]
  end

  local path = M.socket_path(root)

  -- A socket left behind by a Neovim that was killed rather than quit. Probing
  -- it is the only way to tell that from a live one; `sockconnect` throws on a
  -- dead socket, which is the answer we want.
  if vim.uv.fs_stat(path) then
    local ok, channel = pcall(vim.fn.sockconnect, "pipe", path, { rpc = true })
    if ok and channel ~= 0 then
      pcall(vim.fn.chanclose, channel)
      registered[root] = false -- somebody live is already listening
      return false
    end
    vim.fn.delete(path)
  end

  local ok = pcall(vim.fn.serverstart, path)
  registered[root] = ok
  return ok
end

--- Open a file at a position, on behalf of Unity. Called over RPC by the shim.
---
--- The payload is base64 of `path\tline\tcolumn`, which is how a filename with
--- a quote or a space in it survives the trip through a shell.
---@param payload string
function M.open(payload)
  local decoded = vim.base64.decode(payload)
  local path, line, column = unpack(vim.split(decoded, "\t", { plain = true }))
  if not path or path == "" then return 0 end

  vim.schedule(function()
    vim.cmd.edit(vim.fn.fnameescape(path))
    local row = math.max(1, tonumber(line) or 1)
    local col = math.max(0, (tonumber(column) or 1) - 1)
    local last = vim.api.nvim_buf_line_count(0)
    vim.api.nvim_win_set_cursor(0, { math.min(row, last), col })
    vim.cmd "normal! zz"
    -- Unity is the foreground window when you double-click a script, so say
    -- something: the file changed under a terminal you were not looking at.
    vim.notify(("Opened %s:%d from Unity"):format(vim.fs.basename(path), row), vim.log.levels.INFO, { title = "Unity" })
  end)
  return 1
end

-- The shim itself. `$UNITY_NVIM_TERMINAL` is the escape hatch for the case
-- where no Neovim has the project open: without a terminal to put it in there
-- is nowhere for a new one to go, so by default we say so via the desktop
-- notifier rather than silently doing nothing.
local SCRIPT = [==[#!/usr/bin/env bash
# Unity's "Visual Studio Code", which is actually Neovim.
#
# Generated by `:UnityShim` from ~/.config/nvim/lua/user/unity_shim.lua.
# Do not edit -- re-run `:UnityShim` instead.
#
# Unity calls this as:
#     code "<project dir>"
#     code "<project dir>" -g "<file>":<line>:<column>
set -uo pipefail

project="${1:-}"
target=""
while [ $# -gt 0 ]; do
  if [ "$1" = "-g" ]; then
    shift
    target="${1:-}"
    break
  fi
  shift
done

runtime="${XDG_RUNTIME_DIR:-/tmp}/nvim-unity"
key=$(printf '%s' "$project" | sha256sum | cut -c1-16)
sock="$runtime/$key.sock"

if [ -n "$target" ] && [ -S "$sock" ]; then
  # "path:line:column", but a path can contain colons, so peel from the right.
  rest="${target##*:}"; head="${target%:*}"
  col="$rest"; line="${head##*:}"; file="${head%:*}"
  case "$col$line" in
    *[!0-9]*) file="$target"; line=1; col=1 ;;
  esac
  payload=$(printf '%s\t%s\t%s' "$file" "$line" "$col" | base64 -w0)
  if nvim --server "$sock" --remote-expr "UnityOpenFromEditor('$payload')" >/dev/null 2>&1; then
    exit 0
  fi
fi

# No Neovim has this project open (or it stopped answering).
if [ -n "${UNITY_NVIM_TERMINAL:-}" ]; then
  cd "$project" 2>/dev/null || true
  if [ -n "$target" ]; then
    exec $UNITY_NVIM_TERMINAL nvim "+normal! ${target#*:}gg" "${target%%:*}"
  fi
  exec $UNITY_NVIM_TERMINAL nvim .
fi

message="No Neovim is listening for $(basename "$project"). Open the project in Neovim first."
command -v notify-send >/dev/null 2>&1 && notify-send "Unity -> Neovim" "$message"
echo "$message" >&2
exit 0
]==]

--- Write the shim to disk. Safe to re-run; overwrites in place.
---@return boolean ok
function M.install()
  vim.fn.mkdir(vim.fs.dirname(M.shim), "p")
  local fd, err = io.open(M.shim, "w")
  if not fd then
    vim.notify(("Could not write %s: %s"):format(M.shim, err), vim.log.levels.ERROR, { title = "Unity" })
    return false
  end
  fd:write(SCRIPT)
  fd:close()
  vim.uv.fs_chmod(M.shim, 493) -- 0755

  vim.notify(
    ('Shim installed at %s\n\nIn Unity: Edit > Preferences > External Tools >\n  External Script Editor > Browse... > that path.\n\nUnity will then show it as "Visual Studio Code", bind its control\nsocket (Play/Pause/Refresh/tests), and regenerate SDK-style csproj\nfiles with the Unity analyzers attached.'):format(
      M.shim
    ),
    vim.log.levels.INFO,
    { title = "Unity" }
  )
  return true
end

--- Report what is and is not wired up. `:UnityStatus`.
---
--- The Unity control socket is the one thing here that cannot be answered by
--- looking at the filesystem -- it takes a round trip -- so every other line is
--- built first and the notification waits for that one.
function M.status()
  local unity = require "user.unity"
  local dap = require "user.unity_dap"

  local lines = {}
  local function add(ok, text) table.insert(lines, ("%s %s"):format(ok and "OK  " or "--  ", text)) end

  add(vim.fn.executable(M.shim) == 1, ("shim: %s"):format(M.shim))
  add(dap.extension_path() ~= nil, ("debug adapter: %s"):format(dap.extension_path() or "NOT INSTALLED"))

  local root = unity.root()
  if not root then
    add(false, "not inside a Unity project")
    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "Unity status" })
    return
  end

  add(true, ("project: %s (Unity %s)"):format(root, unity.editor_version(root) or "?"))
  add(unity.solution(root) ~= nil, ("solution: %s"):format(unity.solution(root) or "none found"))
  add(vim.uv.fs_stat(M.socket_path(root)) ~= nil, "open-from-Unity socket bound")

  local instance = require("user.unity_editor").for_project(root)
  if not instance then
    add(false, "no Unity editor running for this project")
    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "Unity status" })
    return
  end

  add(
    true,
    ("editor: pid %d, debug port %d, messaging port %d"):format(
      instance.pid,
      instance.debug_port,
      instance.message_port
    )
  )

  require("user.unity_messenger").ping(instance, function(listening)
    add(listening, "Unity control socket answering (Play / Refresh / tests)")
    if not listening then
      table.insert(lines, "")
      table.insert(lines, "Set Unity's External Script Editor to the shim above; `:UnityShim` writes it.")
    end
    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "Unity status" })
  end)
end

return M
