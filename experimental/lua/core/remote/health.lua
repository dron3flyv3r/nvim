local M = {}

function M.check()
  local health = vim.health
  local ssh = require "core.remote.ssh"
  local hosts = require "core.remote.hosts"
  health.start "remote"

  for _, binary in ipairs { "ssh", "scp" } do
    local path = vim.fn.exepath(binary)
    if path == "" then
      health.error(binary .. " is not on PATH", "install openssh")
    else
      health.ok(binary .. ": " .. path)
    end
  end

  local version = vim.system({ "ssh", "-V" }, { text = true }):wait(2000)
  local major, minor = ((version.stderr or "") .. (version.stdout or "")):match "OpenSSH_(%d+)%.(%d+)"
  if not major then
    health.warn "could not read the OpenSSH version"
  elseif tonumber(major) > 6 or (tonumber(major) == 6 and tonumber(minor) >= 7) then
    health.ok(("OpenSSH %s.%s"):format(major, minor))
  else
    health.error(
      ("OpenSSH %s.%s is too old"):format(major, minor),
      "6.7 or newer is needed to forward a unix socket, which is how the editor's socket is reached"
    )
  end

  local control = vim.fs.dirname(ssh.control_path())
  if vim.fn.isdirectory(control) == 1 and vim.fn.filewritable(control) == 2 then
    health.ok("control sockets: " .. control)
  else
    health.error(control .. " is not a writable directory")
  end

  -- netrw moved into an opt package on 0.13; without its handler scp:// is an
  -- ordinary file name and the quick-edit path silently creates a local file.
  if vim.fn.exists "#Network#BufReadCmd#scp://*" == 1 then
    health.ok "netrw answers scp:// -- single-file editing works"
  else
    health.error("nothing handles scp:// reads", "netrw is missing: check that g:loaded_netrw is not set")
  end

  local all = hosts.all()
  if #all == 0 then health.info "no servers added yet -- add one with <Leader>oa" end
  for _, host in ipairs(all) do
    local connected = ssh.connected(host.dest)
    health.info(("%s (%s): %s"):format(host.name, host.dest, connected and "connected" or "not connected"))
    if connected then
      local answer, failure
      ssh.script(host.dest, 'echo "$(uname -s) $(uname -m)"\n', function(lines, why)
        answer, failure = lines and vim.trim(lines[1] or "") or "", why or "it answered nothing"
      end)
      vim.wait(10000, function() return answer ~= nil end, 100)
      if answer and answer ~= "" then
        health.ok(("%s runs a script: %s"):format(host.name, answer))
      else
        health.error(
          ("%s does not run a script: %s"):format(host.name, failure or "it did not answer within 10s"),
          "every request here is one shell script; a login shell that prints to stdout or refuses to run breaks all of it"
        )
      end
    end
  end
end

return M
