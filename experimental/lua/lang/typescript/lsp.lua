local M = {}

M.FILETYPES = { "javascript", "javascriptreact", "typescript", "typescriptreact" }

local ESLINT_CONFIGS = {
  "eslint.config.js",
  "eslint.config.mjs",
  "eslint.config.cjs",
  "eslint.config.ts",
  "eslint.config.mts",
  "eslint.config.cts",
  ".eslintrc",
  ".eslintrc.js",
  ".eslintrc.cjs",
  ".eslintrc.json",
  ".eslintrc.yaml",
  ".eslintrc.yml",
}

local INLAY_HINTS = {
  parameterNames = { enabled = "all", suppressWhenArgumentMatchesName = true },
  parameterTypes = { enabled = true },
  variableTypes = { enabled = true, suppressWhenTypeMatchesName = true },
  propertyDeclarationTypes = { enabled = true },
  functionLikeReturnTypes = { enabled = true },
  enumMemberValues = { enabled = true },
}

local LANGUAGE = {
  inlayHints = INLAY_HINTS,
  referencesCodeLens = { enabled = true, showOnAllFunctions = false },
  implementationsCodeLens = { enabled = true },
  updateImportsOnFileMove = { enabled = "always" },
  suggest = { completeFunctionCalls = false },
}

---@param command lsp.Command
---@param ctx { client_id: integer }
local function show_references(command, ctx)
  local client = vim.lsp.get_client_by_id(ctx.client_id)
  local locations = command.arguments and command.arguments[3] or {}
  local items = vim.lsp.util.locations_to_items(locations, client and client.offset_encoding or "utf-16")
  if #items == 0 then return vim.notify("No locations", vim.log.levels.INFO, { title = "TypeScript" }) end
  if #items == 1 then
    vim.cmd.edit(items[1].filename)
    return pcall(vim.api.nvim_win_set_cursor, 0, { items[1].lnum, items[1].col - 1 })
  end
  vim.fn.setqflist({}, " ", { title = "Code Lens", items = items })
  require("snacks").picker.qflist { focus = "list" }
end

---@return boolean
function M.has_vtsls() return vim.fn.executable "vtsls" == 1 end

---@return boolean
function M.has_eslint() return vim.fn.executable "vscode-eslint-language-server" == 1 end

---@param bufnr integer
---@param on_dir fun(dir: string)
local function eslint_root(bufnr, on_dir)
  local root = vim.fs.root(bufnr, ESLINT_CONFIGS)
  if root then on_dir(root) end
end

---@param _ lsp.InitializeParams
---@param config vim.lsp.ClientConfig
local function eslint_workspace(_, config)
  local root = config.root_dir
  if not root then return end
  config.settings.workspaceFolder = { uri = vim.uri_from_fname(root), name = vim.fs.basename(root) }
  for _, name in ipairs(ESLINT_CONFIGS) do
    if name:match "^eslint%.config" and vim.uv.fs_stat(vim.fs.joinpath(root, name)) then
      config.settings.experimental = { useFlatConfig = true }
      config.settings.useFlatConfig = true
      return
    end
  end
end

local function eslint_config()
  local function warn(message)
    return function()
      vim.notify(message, vim.log.levels.WARN, { title = "ESLint" })
      return {}
    end
  end
  return {
    cmd = { "vscode-eslint-language-server", "--stdio" },
    filetypes = M.FILETYPES,
    root_dir = eslint_root,
    before_init = eslint_workspace,
    settings = {
      validate = "on",
      useESLintClass = false,
      codeActionOnSave = { enable = false, mode = "all" },
      format = false,
      quiet = false,
      onIgnoredFiles = "off",
      rulesCustomizations = {},
      run = "onType",
      problems = { shortenToSingleLine = false },
      nodePath = "",
      workingDirectory = { mode = "location" },
      codeAction = {
        disableRuleComment = { enable = true, location = "separateLine" },
        showDocumentation = { enable = true },
      },
    },
    handlers = {
      ["eslint/openDoc"] = function(_, result)
        if result and result.url then vim.ui.open(result.url) end
        return {}
      end,
      -- 4 is "approved": the server otherwise refuses to run a project-local ESLint.
      ["eslint/confirmESLintExecution"] = function(_, result) return result and 4 or nil end,
      ["eslint/probeFailed"] = warn "ESLint could not load this project's configuration",
      ["eslint/noLibrary"] = warn "ESLint is not installed in this project",
    },
  }
end

---@return table<string, vim.lsp.Config>|nil
function M.config()
  local servers = {}
  if M.has_vtsls() then
    servers.vtsls = {
      cmd = { "vtsls", "--stdio" },
      filetypes = M.FILETYPES,
      root_markers = { "tsconfig.json", "jsconfig.json", "package.json", ".git" },
      commands = { ["editor.action.showReferences"] = show_references },
      settings = {
        vtsls = {
          autoUseWorkspaceTsdk = true,
          experimental = { completion = { enableServerSideFuzzyMatch = true } },
        },
        typescript = LANGUAGE,
        javascript = LANGUAGE,
      },
    }
  end
  if M.has_eslint() then servers.eslint = eslint_config() end
  return next(servers) and servers or nil
end

return M
