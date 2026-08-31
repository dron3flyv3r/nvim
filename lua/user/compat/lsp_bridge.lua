-- Reconnecting AstroLSP to the servers Mason installs.
--
-- ── THE SYMPTOM ──────────────────────────────────────────────────────────────
--
-- `gd` did nothing useful. On `new HelpImageButton()` it jumped somewhere
-- random or nowhere, while `grr` (references) and `K` (hover) worked fine.
--
-- The reason is that `gd` was never mapped. Neovim 0.11+ binds `grr`, `gri`,
-- `grn`, `gra`, `gO` and `K` to LSP itself -- those are core defaults and they
-- worked. `gd`, `gD`, `gI` and `gy` are AstroLSP's, applied in its `on_attach`,
-- and `on_attach` was never running. With nothing mapped to it, `gd` fell
-- through to Vim's built-in "go to local declaration", which is a text search
-- of the enclosing function -- fine for a C local, useless for a C# type.
--
-- The check that shows it, in any buffer with a server attached:
--
--     :lua =require("astrolsp").attached_clients
--     {}
--
-- ── THE CAUSE ────────────────────────────────────────────────────────────────
--
-- AstroNvim v5 drives AstroLSP through **mason-lspconfig v1**. Its
-- `plugins/lspconfig.lua` pins `version = "^1"` and passes v1's per-server hook:
--
--     handlers = { function(server) require("astrolsp").lsp_setup(server) end }
--
-- The plugin actually installed is **v2** (`mason-org/mason-lspconfig.nvim`,
-- pulled in by `astrocommunity.pack.lua`). v2 deleted `handlers` and replaced it
-- with `automatic_enable`, which calls `vim.lsp.enable(server)` directly and
-- knows nothing about AstroLSP. So `astrolsp.lsp_setup` is never called for a
-- Mason-installed server, and everything that hangs off it is dead:
--
--   * `on_attach` -- so no `gd`/`gD`/`gI`/`gy`, no codelens refresh, no
--     `<Leader>uY`, and no format-on-save autocmd at all;
--   * `config.<server>` -- so `python-lsp.lua`'s `unused_off` overrides never
--     reached basedpyright, and Ruff and the type checker both reported every
--     unused import;
--   * `handlers.<server> = false` -- so `pyright = false` was ignored and
--     pyright ran alongside basedpyright, which is the one thing that file
--     exists to prevent.
--
-- ── THE FIX ──────────────────────────────────────────────────────────────────
--
-- Put v1's contract back, in the one place it belongs: for each server Mason has
-- installed, call `astrolsp.lsp_setup(server)`. That is a single function which
-- already does the whole job -- it resolves AstroLSP's `config` for the server,
-- wraps `on_attach`, consults `handlers`, and enables the server (or does not,
-- if the handler is `false`).
--
-- `automatic_enable` is switched off in the spec next door, because otherwise
-- both paths enable servers and `handlers.<x> = false` cannot win: Mason would
-- turn pyright on again immediately after AstroLSP declined to.
--
-- This is a shim over an upstream mismatch. When AstroNvim ships v2 support --
-- its own roadmap note says "Move `on_attach` to an autocommand on `LspAttach`"
-- -- this file and its spec should be deleted, and `handlers`/`config` will go
-- back to working on their own.

local M = {}

--- Servers already handed to AstroLSP. `lsp_setup` is idempotent, but Mason
--- fires `package:install:success` per install and there is no reason to redo
--- the work.
---@type table<string, true>
local configured = {}

--- The lspconfig server names behind the packages Mason has installed.
---
--- Mason's registry is the same source `automatic_enable` reads, so this
--- enables exactly the set that used to be enabled -- no more, no less.
---@return string[]
local function installed_servers()
  local registry_ok, registry = pcall(require, "mason-registry")
  local mappings_ok, mappings = pcall(require, "mason-lspconfig.mappings")
  if not (registry_ok and mappings_ok) then return {} end

  local package_to_server = mappings.get_mason_map().package_to_lspconfig
  local servers = {}
  for _, package in ipairs(registry.get_installed_package_names()) do
    local server = package_to_server[package]
    if server then servers[server] = true end
  end
  return vim.tbl_keys(servers)
end

--- Hand every installed server to AstroLSP. Safe to call more than once.
function M.setup()
  local astrolsp_ok, astrolsp = pcall(require, "astrolsp")
  if not astrolsp_ok then return end

  local started = false
  for _, server in ipairs(installed_servers()) do
    if not configured[server] then
      configured[server] = true

      -- A configuration has to exist somewhere on the runtimepath, or
      -- `vim.lsp.enable` logs a warning at every matching `FileType` for a
      -- server that can never start. Checked as a file rather than by indexing
      -- `vim.lsp.config`, because indexing resolves and caches the config and
      -- this runs before AstroLSP has had its say.
      if #vim.api.nvim_get_runtime_file("lsp/" .. server .. ".lua", false) > 0 then
        -- mason-lspconfig's own per-server override first, so AstroLSP's
        -- `config` merges on top of it. This is the order `automatic_enable`
        -- used, and none of the servers installed here actually has one -- it
        -- is here so that installing, say, `pylsp` later does not quietly
        -- change behaviour.
        local override_ok, override = pcall(require, "mason-lspconfig.lsp." .. server)
        if override_ok then vim.lsp.config(server, override) end

        astrolsp.lsp_setup(server)
        started = true
      end
    end
  end

  if not started then return end

  -- `vim.lsp.enable` only re-runs `FileType` for already-open buffers once
  -- `VimEnter` has fired. Starting Neovim *on* a file gets here first, during
  -- startup, so that buffer would sit there with no server until you touched
  -- another one. Same kick as `python-lsp.lua` uses for pyrefly, and a no-op
  -- when there is nothing to start.
  vim.schedule(function() pcall(vim.cmd.doautoall, "nvim.lsp.enable FileType") end)
end

return M
