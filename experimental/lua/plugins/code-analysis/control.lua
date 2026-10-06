local M = {}

M.CLIENT = "sonarlint.nvim"
M.CONNECTION = "sonarqube"

---@class plugins.analysis.Paths
---@field extension string
---@field analyzers string
---@field server string

---@class plugins.analysis.Language
---@field filetypes string[]
---@field analyzers string[]
---@field executables? string[]
---@field init_options? fun(paths: plugins.analysis.Paths): table
---@field settings? fun(root: string): table

---@class plugins.analysis.Opts
---@field languages table<string, plugins.analysis.Language>

---@class plugins.analysis.Device
---@field url? string
---@field projects? table<string, string>
---@field token? fun(): string?

---@type plugins.analysis.Device?
local device

---@type table<string, plugins.analysis.Language>
M.languages = {}

---@type table<string, true>
local filetypes = {}

local function notify(message, level) vim.notify(message, level or vim.log.levels.INFO, { title = "Sonar" }) end

---@return plugins.analysis.Device?
function M.device() return device end

---@return plugins.analysis.Paths
function M.paths()
  local extension = vim.env.SONARLINT_HOME
    or vim.fs.joinpath(
      vim.fn.stdpath "data" --[[@as string]],
      "mason",
      "packages",
      "sonarlint-language-server",
      "extension"
    )
  return {
    extension = extension,
    analyzers = vim.fs.joinpath(extension, "analyzers"),
    server = vim.fs.joinpath(extension, "server", "sonarlint-ls.jar"),
  }
end

---@return string
function M.java()
  local home = vim.env.JAVA_HOME
  if home and vim.fn.executable(home .. "/bin/java") == 1 then return home .. "/bin/java" end
  return "java"
end

---@return string?
function M.token()
  local token = device and device.token and device.token() or vim.env.SONAR_TOKEN
  if token and token ~= "" then return token end
end

---@param root string
---@return string?
function M.project_key(root)
  for path, key in pairs(device and device.projects or {}) do
    if vim.fs.normalize(path) == root then return key end
  end
  local properties = vim.fs.joinpath(root, "sonar-project.properties")
  if not vim.uv.fs_stat(properties) then return end
  for line in io.lines(properties) do
    local key = line:match "^%s*sonar%.projectKey%s*[=:]%s*(%S+)"
    if key then return key end
  end
end

---@param bufnr? integer
---@return vim.lsp.Client?
function M.client(bufnr) return vim.lsp.get_clients({ name = M.CLIENT, bufnr = bufnr })[1] end

---@param client vim.lsp.Client
---@return string
function M.connection(client)
  local states = require("sonarlint.connected_mode")._connected_clients
  local state = states and states[client.id]
  if not state then return "local mode, Sonar's default rules" end
  return state
end

---@param target table
---@param source table
local function merge_into(target, source)
  for key, value in pairs(source) do
    if type(value) == "table" and type(target[key]) == "table" then
      target[key] = vim.tbl_deep_extend("force", target[key], value)
    else
      target[key] = value
    end
  end
end

-- `config.settings` is the table the client already answers
-- workspace/configuration from, so it is filled in place rather than replaced.
---@param config vim.lsp.ClientConfig
local function before_init(_, config)
  local root = config.root_dir --[[@as string]]
  local key = M.project_key(root)
  config.settings.sonarlint.connectedMode.project = key and { connectionId = M.CONNECTION, projectKey = key } or nil
  for _, language in pairs(M.languages) do
    if language.settings then merge_into(config.settings, language.settings(root)) end
  end
end

---@param language plugins.analysis.Language
---@return string?
local function missing_executable(language)
  for _, executable in ipairs(language.executables or {}) do
    if vim.fn.executable(executable) ~= 1 then return executable end
  end
end

---@param paths plugins.analysis.Paths
---@return table server, string[] fts
local function server(paths)
  local cmd = { M.java(), "-jar", paths.server, "-stdio", "-analyzers" }
  local init_options = {}
  local fts = {}
  for name, language in pairs(M.languages) do
    local missing = missing_executable(language)
    if missing then
      notify(("%s is not on PATH; Sonar will not analyse %s"):format(missing, name), vim.log.levels.WARN)
    else
      for _, jar in ipairs(language.analyzers) do
        table.insert(cmd, vim.fs.joinpath(paths.analyzers, jar))
      end
      vim.list_extend(fts, language.filetypes)
      if language.init_options then
        init_options = vim.tbl_extend("force", init_options, language.init_options(paths))
      end
    end
  end
  return {
    cmd = cmd,
    init_options = init_options,
    before_init = before_init,
    settings = {
      sonarlint = {
        connectedMode = {
          connections = {
            sonarqube = { { connectionId = M.CONNECTION, serverUrl = device.url, disableNotifications = true } },
          },
        },
      },
    },
  },
    fts
end

---@param bufnr integer
---@return boolean
local function analysable(bufnr)
  return vim.bo[bufnr].buftype == "" and not vim.api.nvim_buf_get_name(bufnr):match "^%a[%w+.-]*://"
end

local PUBLISH = "textDocument/publishDiagnostics"
local LOG = "window/logMessage"

---@type table<integer, true>
local analysed = {}

---@class plugins.analysis.Batch
---@field buffers integer[]
---@field timed_out? boolean

---@type table<integer, plugins.analysis.Batch>
local batches = {}

---@type table<integer, true>
local finishing = {}

---@param bufnr integer
---@return boolean
function M.analysed(bufnr) return analysed[bufnr] == true end

---@param bufnr integer
---@return boolean
function M.handles(bufnr) return filetypes[vim.bo[bufnr].filetype] == true end

---@param bufnr integer
---@return vim.Diagnostic[]
function M.diagnostics(bufnr)
  local client = M.client(bufnr)
  if not client then return {} end
  return vim.diagnostic.get(bufnr, { namespace = vim.lsp.diagnostic.get_namespace(client.id) })
end

---@param message string
---@return integer[]
local function batch_buffers(message)
  local buffers = {}
  for uri in message:gmatch "(file://%S+) %(" do
    local bufnr = vim.fn.bufnr(vim.uri_to_fname(uri))
    if bufnr > 0 then
      buffers[#buffers + 1] = bufnr
      analysed[bufnr] = nil
    end
  end
  return buffers
end

---@param batch plugins.analysis.Batch
local function finish(batch)
  if batch.timed_out then return end
  for _, bufnr in ipairs(batch.buffers) do
    finishing[bufnr] = true
  end
  vim.defer_fn(function()
    for _, bufnr in ipairs(batch.buffers) do
      if finishing[bufnr] then
        analysed[bufnr], finishing[bufnr] = true, nil
      end
    end
  end, 2000)
end

-- Issues are streamed while a batch runs, so a publish proves nothing until the
-- batch's closing log line; the final publish for each file follows it.
---@param client_id integer
---@param message string
local function watch_log(client_id, message)
  if message:find("Starting analysis with configuration", 1, true) then
    batches[client_id] = { buffers = batch_buffers(message) }
  elseif message:find("Timeout waiting for the solution to be loaded", 1, true) then
    if batches[client_id] then batches[client_id].timed_out = true end
    notify(
      "C# analysis timed out loading the solution, so C# issues are missing; edit the file to retry",
      vim.log.levels.WARN
    )
  elseif message:find("] Analysis detected ", 1, true) and batches[client_id] then
    finish(batches[client_id])
    batches[client_id] = nil
  end
end

---@param client vim.lsp.Client
local function track_analysis(client)
  if client.handlers[LOG] then return end
  client.handlers[PUBLISH] = function(err, result, ctx)
    local bufnr = result and vim.fn.bufnr(vim.uri_to_fname(result.uri)) or -1
    if finishing[bufnr] then
      analysed[bufnr], finishing[bufnr] = true, nil
    end
    return vim.lsp.handlers[PUBLISH](err, result, ctx)
  end
  client.handlers[LOG] = function(err, result, ctx)
    if result and result.message then watch_log(ctx.client_id, result.message) end
    return vim.lsp.handlers[LOG](err, result, ctx)
  end
end

local function watch_clients()
  local group = vim.api.nvim_create_augroup("plugins_code_analysis", {})
  vim.api.nvim_create_autocmd("LspAttach", {
    group = group,
    callback = function(args)
      local client = vim.lsp.get_client_by_id(args.data.client_id)
      if not client or client.name ~= M.CLIENT then return end
      track_analysis(client)
      if analysable(args.buf) then return end
      -- The plugin attaches on FileType alone, which includes a review's
      -- diffview:// panes and would put a second set of issues on the old side.
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(args.buf) then vim.lsp.buf_detach_client(args.buf, client.id) end
      end)
    end,
    desc = "Track Sonar's analyses and keep it on file buffers",
  })
  vim.api.nvim_create_autocmd("BufUnload", {
    group = group,
    callback = function(args)
      analysed[args.buf], finishing[args.buf] = nil, nil
    end,
    desc = "Forget Sonar's analysis of an unloaded buffer",
  })
end

---@param ctx core.Context
---@return boolean|string
local function attached(ctx)
  if M.client(ctx.bufnr) then return true end
  return "The Sonar server is not attached to this buffer"
end

---@param bufnr integer
---@return string?
function M.root(bufnr)
  local client = M.client(bufnr)
  return client and client.config.root_dir or vim.fs.root(bufnr, ".git")
end

---@param ctx core.Context
---@return string?
local function bound_key(ctx)
  local root = M.root(ctx.bufnr)
  return root and M.project_key(root)
end

local NOT_BOUND = "No project key for this root; add it to projects in lua/user or sonar-project.properties"

---@param ctx core.Context
---@return boolean|string
local function bound(ctx) return bound_key(ctx) ~= nil or NOT_BOUND end

local provider = {
  id = "code_analysis",
  name = "Sonar",
  priority = -10,
  detect = function(ctx)
    if not filetypes[ctx.filetype] then return false end
    local key = bound_key(ctx)
    return key and ("bound to " .. key) or true
  end,
  actions = function()
    return {
      {
        id = "pull_request",
        label = "Show the pull request's issues on SonarQube",
        category = "Inspect",
        available = bound,
        run = function(ctx) require("plugins.code-analysis.report").open(M.root(ctx.bufnr), bound_key(ctx)) end,
      },
      {
        id = "reanalyse",
        label = "Re-analyse the PR report's files locally",
        category = "Inspect",
        available = bound,
        run = function(ctx)
          require("plugins.code-analysis.report").reanalyse(M.root(ctx.bufnr) --[[@as string]])
        end,
      },
      {
        id = "connection",
        label = "Show the Sonar connection",
        category = "Inspect",
        repeatable = false,
        available = attached,
        run = function(ctx)
          local client = M.client(ctx.bufnr) --[[@as vim.lsp.Client]]
          notify(
            ("%s\nproject: %s\nconnection: %s"):format(
              client.config.root_dir,
              bound_key(ctx) or "not bound",
              M.connection(client)
            )
          )
        end,
      },
      {
        id = "open_project",
        label = "Open the project on the SonarQube server",
        category = "Open",
        repeatable = false,
        available = bound,
        run = function(ctx)
          vim.ui.open(("%s/dashboard?id=%s"):format(device.url:gsub("/+$", ""), vim.uri_encode(bound_key(ctx))))
        end,
      },
    }
  end,
  status = function(ctx)
    local client = M.client(ctx.bufnr)
    if not client then return { "server not attached" } end
    return { ("root %s, %s"):format(client.config.root_dir, M.connection(client)) }
  end,
}

function M.cached_report()
  local bufnr = vim.api.nvim_get_current_buf()
  local root = M.root(bufnr)
  local key = root and M.project_key(root)
  if not device then return notify("SonarQube is not enabled on this device; see lua/user", vim.log.levels.WARN) end
  if not key then return notify(NOT_BOUND, vim.log.levels.WARN) end
  require("plugins.code-analysis.report").cached(root --[[@as string]], key)
end

---@param opts plugins.analysis.Opts
function M.setup(opts)
  M.languages = opts.languages or {}
  if not device then return end
  local paths = M.paths()
  if not vim.uv.fs_stat(paths.server) then
    notify("sonarlint-language-server is not installed; :MasonInstall sonarlint-language-server", vim.log.levels.WARN)
    return
  end
  local config, fts = server(paths)
  if #fts == 0 then return end
  for _, ft in ipairs(fts) do
    filetypes[ft] = true
  end
  require("sonarlint").setup {
    server = config,
    filetypes = fts,
    -- Neovim rejects a nil reply to a server request; the plugin reads vim.NIL as no token.
    connected = { get_credentials = function() return M.token() or vim.NIL end },
  }
  watch_clients()
  require("core.actions").register(provider)
end

---@param opts plugins.analysis.Device
function M.enable(opts)
  if device then return end
  if not opts.url or opts.url == "" then
    notify("No SonarQube server URL; set SONAR_HOST_URL or pass url to enable()", vim.log.levels.WARN)
    return
  end
  device = opts
  require("lazy").load { plugins = { "sonarlint.nvim" } }
end

return M
