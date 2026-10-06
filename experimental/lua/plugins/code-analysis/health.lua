local M = {}

---@param java string
---@return integer?
local function java_major(java)
  local ok, result = pcall(function() return vim.system({ java, "-version" }):wait(5000) end)
  if not ok then return end
  local version = (result.stderr or ""):match 'version "([^"]+)"'
  return version and tonumber(version:match "^(%d+)")
end

---@param health table
---@param control table
local function check_install(health, control)
  local java = control.java()
  local major = java_major(java)
  if not major then
    health.error("no Java found at " .. java, "the Sonar server needs Java 17 or newer")
  elseif major < 17 then
    health.error(("Java %d is too old: %s"):format(major, java), "set JAVA_HOME to Java 17 or newer")
  else
    health.ok(("Java %d: %s"):format(major, vim.fn.exepath(java)))
  end

  local paths = control.paths()
  if vim.uv.fs_stat(paths.server) then
    health.ok("server: " .. paths.server)
  else
    health.error("no server at " .. paths.server, ":MasonInstall sonarlint-language-server, or set SONARLINT_HOME")
  end

  for name, language in pairs(control.languages) do
    for _, jar in ipairs(language.analyzers) do
      if not vim.uv.fs_stat(vim.fs.joinpath(paths.analyzers, jar)) then
        health.error(("%s: analyzer %s is missing from %s"):format(name, jar, paths.analyzers))
      end
    end
    for _, executable in ipairs(language.executables or {}) do
      if vim.fn.executable(executable) == 1 then
        health.ok(("%s: %s is on PATH"):format(name, executable))
      else
        health.error(
          ("%s: %s is not on PATH"):format(name, executable),
          "Sonar does not analyse " .. name .. " without it"
        )
      end
    end
  end
end

---@param health table
---@param control table
local function check_connection(health, control)
  local url = control.device().url
  local token = control.token()
  if not token then health.warn("no user token", "set SONAR_TOKEN, or pass token = function() ... end to enable()") end

  local response = require("plugins.code-analysis.api").wait("api/authentication/validate", {})
  local valid, err = response.ok and response.body.valid == true, response.err
  if not response.ok and not response.status then
    health.error(
      ("cannot reach %s: %s"):format(url, err),
      "a bound project is not analysed until its first sync succeeds -- check the VPN"
    )
  elseif not response.ok then
    health.error(("%s answered: %s"):format(url, err))
  elseif valid then
    health.ok(("%s %s"):format(url, token and "accepts the token" or "is reachable and allows anonymous access"))
  elseif token then
    health.error(("%s rejects the token"):format(url), "create a new user token on the server")
  else
    health.warn(("%s is reachable but needs a token"):format(url))
  end

  local root = vim.fs.root(0, ".git") or vim.fn.getcwd()
  local key = control.project_key(root)
  if key then
    health.ok(("%s is bound to %s"):format(root, key))
  else
    health.warn(
      root .. " is not bound to a project, so it runs Sonar's default rules",
      "add it to projects in lua/user, or put sonar.projectKey in sonar-project.properties"
    )
  end

  local client = control.client()
  if client then
    health.ok(("the server is running for %s: %s"):format(client.config.root_dir, control.connection(client)))
  else
    health.info "the server is not running -- it starts with the first file it analyses"
  end
end

function M.check()
  local health = vim.health
  local control = require "plugins.code-analysis.control"
  health.start "code analysis"

  if not control.device() then
    health.info "not enabled on this device -- lua/user opts in with require('plugins.code-analysis.control').enable()"
    return
  end
  check_install(health, control)
  check_connection(health, control)
end

return M
