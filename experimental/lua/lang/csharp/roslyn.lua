local M = {}

---@return string|nil
function M.executable()
  local override = vim.env.ROSLYN_LS
  if override and vim.fn.executable(override) == 1 then return override end
  if vim.fn.executable "roslyn-language-server" == 1 then return "roslyn-language-server" end
  return nil
end

---@param bufnr integer
---@return string|nil
local function unity_root(bufnr)
  local ok, project = pcall(require, "lang.unity.project")
  return ok and project.root(bufnr) or nil
end

---@param dir string
---@return string|nil
local function solution_in(dir)
  local ok, project = pcall(require, "lang.unity.project")
  if ok and project.root(dir) == dir then
    local solution = project.solution(dir)
    if solution then return solution end
  end
  for entry, kind in vim.fs.dir(dir) do
    if kind == "file" and entry:match "%.slnx?$" then return vim.fs.joinpath(dir, entry) end
  end
end

---@param dir string
---@return string[]
local function projects_in(dir)
  local projects = {}
  for entry, kind in vim.fs.dir(dir) do
    if kind == "file" and vim.endswith(entry, ".csproj") then
      table.insert(projects, vim.uri_from_fname(vim.fs.joinpath(dir, entry)))
    end
  end
  return projects
end

---@param bufnr integer
---@param on_dir fun(dir: string)
local function root_dir(bufnr, on_dir)
  local name = vim.api.nvim_buf_get_name(bufnr)

  -- Decompiled sources live outside any project; they belong to whichever
  -- client the jump came from.
  if name:find "[/\\]MetadataAsSource[/\\]" then
    local previous = vim.fn.bufnr "#"
    local clients = vim.lsp.get_clients { name = "roslyn_ls", bufnr = previous ~= -1 and previous or nil }
    if clients[1] and clients[1].config.root_dir then on_dir(clients[1].config.root_dir) end
    return
  end

  local unity = unity_root(bufnr)
  if unity then return on_dir(unity) end

  local found = vim.fs.root(bufnr, function(entry) return entry:match "%.slnx?$" ~= nil end)
    or vim.fs.root(bufnr, function(entry) return entry:match "%.csproj$" ~= nil end)
  if found then on_dir(found) end
end

---@param client vim.lsp.Client
local function on_init(client)
  local dir = client.config.root_dir
  if not dir then return end

  local solution = solution_in(dir)
  if solution then
    client:notify("solution/open", { solution = vim.uri_from_fname(solution) })
    return
  end

  local projects = projects_in(dir)
  if not vim.tbl_isempty(projects) then client:notify("project/open", { projects = projects }) end
end

---@param _ any
---@param __ any
---@param ctx lsp.HandlerContext
local function initialization_complete(_, __, ctx)
  vim.notify("project initialization complete", vim.log.levels.INFO, { title = "roslyn_ls" })

  -- Diagnostics requested while the workspace was still loading came back
  -- empty; nothing re-requests them on its own. Guarded because this is
  -- private and a rename should cost the refresh, not throw from a handler.
  local refresh = vim.lsp.diagnostic._refresh
  local client = refresh and vim.lsp.get_client_by_id(ctx.client_id)
  if not client then return end
  for buf in pairs(client.attached_buffers) do
    pcall(refresh, buf, ctx.client_id)
  end
end

---@return table<string, vim.lsp.Config>|nil
function M.config()
  local exe = M.executable()
  if not exe then return nil end

  return {
    roslyn_ls = {
      cmd = {
        exe,
        -- The server exits immediately without both of these.
        "--logLevel",
        "Information",
        "--extensionLogDirectory",
        vim.fs.joinpath(vim.uv.os_tmpdir(), "roslyn_ls/logs"),
        "--stdio",
      },
      cmd_env = { MSBUILDDISABLENODEREUSE = "1" },
      root_dir = root_dir,
      on_init = on_init,
      handlers = { ["workspace/projectInitializationComplete"] = initialization_complete },
      settings = {
        ["csharp|completion"] = {
          dotnet_show_completion_items_from_unimported_namespaces = true,
          dotnet_show_name_completion_suggestions = true,
          dotnet_provide_regex_completions = true,
        },
        -- A Unity solution is large enough that whole-solution analysis never
        -- settles; scoped to what is open, diagnostics stay current.
        ["csharp|background_analysis"] = {
          dotnet_analyzer_diagnostics_scope = "openFiles",
          dotnet_compiler_diagnostics_scope = "openFiles",
        },
        ["csharp|inlay_hints"] = {
          csharp_enable_inlay_hints_for_implicit_object_creation = true,
          csharp_enable_inlay_hints_for_implicit_variable_types = true,
          csharp_enable_inlay_hints_for_lambda_parameter_types = true,
          dotnet_enable_inlay_hints_for_parameters = true,
        },
      },
    },
  }
end

return M
