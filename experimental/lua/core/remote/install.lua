local M = {}

local ssh = require "core.remote.ssh"
local hosts = require "core.remote.hosts"

local REPO = "https://github.com/dron3flyv3r/nvim.git"
local APPNAME = "nvim/experimental"

---@param message string
---@param level? integer
local function notify(message, level) vim.notify(message, level or vim.log.levels.INFO, { title = "Remote" }) end

-- lua/user is a submodule of per-device overrides, and a server is a different
-- device: the clone deliberately does not recurse into it.
---@return string
local function script()
  return ([[
set -e

for tool in curl tar git; do
  command -v "$tool" >/dev/null 2>&1 || { echo "MISSING $tool -- install it and run this again" >&2; exit 1; }
done

case "$(uname -m)" in
  x86_64) asset="nvim-linux-x86_64" ;;
  aarch64|arm64) asset="nvim-linux-arm64" ;;
  *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac

versions="$HOME/.local/share/nvim-versions"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "==> downloading ${asset}.tar.gz (nightly)"
curl -fsSL --retry 3 \
  "https://github.com/neovim/neovim/releases/download/nightly/${asset}.tar.gz" \
  -o "$tmp/nvim.tar.gz"
tar -xzf "$tmp/nvim.tar.gz" -C "$tmp"

version="$("$tmp/$asset/bin/nvim" --version | head -1 | cut -d' ' -f2)"
mkdir -p "$versions"
if [ -d "$versions/$version" ]; then
  echo "==> $version already installed"
else
  mv "$tmp/$asset" "$versions/$version"
  echo "==> installed $version"
fi
ln -sfn "$versions/$version" "$versions/current"
nvim="$versions/current/bin/nvim"

config="$HOME/.config/nvim"
if [ -d "$config/.git" ]; then
  echo "==> updating the config in $config"
  git -C "$config" pull --ff-only
elif [ -e "$config" ]; then
  echo "$config exists and is not a git checkout -- move it aside and run this again" >&2
  exit 1
else
  echo "==> cloning the config into $config"
  mkdir -p "$(dirname "$config")"
  git clone --depth 1 %s "$config"
fi

if [ ! -d "$config/experimental" ]; then
  echo "$config has no experimental/ directory -- wrong repository?" >&2
  exit 1
fi

echo "==> installing plugins"
NVIM_APPNAME=%s "$nvim" --headless "+Lazy! sync" +qa

mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/nv" <<'EOF'
#!/bin/sh
NVIM_APPNAME=%s exec "$HOME/.local/share/nvim-versions/current/bin/nvim" "$@"
EOF
chmod +x "$HOME/.local/bin/nv"

echo "REMOTE SETUP OK $version"
]]):format(REPO, APPNAME, APPNAME)
end

-- The exit code is not enough: a remote shell that ran nothing still exits 0,
-- which is how a setup that installed nothing once reported itself installed.
---@param task core.Task
---@return boolean
local function reported_success(task)
  if not vim.api.nvim_buf_is_valid(task.bufnr) then return false end
  for _, line in ipairs(vim.api.nvim_buf_get_lines(task.bufnr, 0, -1, false)) do
    if line:find("REMOTE SETUP OK", 1, true) then return true end
  end
  return false
end

---@param host core.remote.Host
---@param on_done? fun()
function M.run(host, on_done)
  ssh.connect(host.dest, function(ok, err)
    if not ok then return notify(err or "could not connect to " .. host.name, vim.log.levels.ERROR) end
    require("core.task").run {
      name = "remote setup: " .. host.name,
      cmd = ssh.cmd(host.dest, ssh.script_argv(script())),
      queue = false,
      focus = true,
      on_exit = function(task)
        if task.status ~= "success" or not reported_success(task) then
          return notify("Setup failed on " .. host.name .. " -- the output is in the pane", vim.log.levels.ERROR)
        end
        notify("The config is installed on " .. host.name)
        if on_done then on_done() end
      end,
    }
  end)
end

---@param host core.remote.Host
---@param on_done? fun() what the install was in the way of, retried when it succeeds
function M.offer(host, on_done)
  vim.ui.select({ true, false }, {
    prompt = "Neovim is not installed on " .. host.name,
    format_item = function(item)
      if item then return "Install Neovim and this config on " .. host.name end
      return "Cancel"
    end,
  }, function(choice)
    if choice then M.run(host, on_done) end
  end)
end

function M.pick()
  hosts.pick("Install the config on", function(host) M.run(host) end)
end

return M
