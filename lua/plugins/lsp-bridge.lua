-- Wiring for `user.lsp_bridge`, which is where the whole explanation lives:
-- AstroNvim v5 talks to mason-lspconfig v1, the installed plugin is v2, and the
-- result was that AstroLSP never saw a single Mason-installed server.
---@type LazySpec
return {
  {
    -- v2's own enabling has to be off, or it and AstroLSP both enable servers
    -- and `handlers.<x> = false` can never win -- Mason would switch pyright
    -- back on immediately after AstroLSP declined to.
    --
    -- NOTE: this is what makes the `automatic_enable == false` guard in
    -- `plugins/unity.lua` fire, so the `omnisharp`/`csharp_ls` exclusions there
    -- become no-ops and the `handlers` entries below do that job instead.
    "mason-org/mason-lspconfig.nvim",
    optional = true,
    opts = { automatic_enable = false },
  },

  {
    "AstroNvim/astrolsp",
    ---@type AstroLSPOpts
    opts = {
      -- THE OTHER HALF OF THE BREAK, AND THE SUBTLER ONE.
      --
      -- `astrolsp.lsp_setup(server)` has two code paths. With this flag off --
      -- which is the default, and nothing in AstroNvim or astrocommunity turns
      -- it on -- it takes the pre-0.11 route: `lspconfig[server].setup(opts)`,
      -- the old framework. On Neovim 0.12 with `nvim-lspconfig`'s current
      -- `lsp/` layout that call registers nothing and starts nothing, silently.
      --
      -- So the first version of this bridge iterated every installed server,
      -- called `lsp_setup` on each, got no errors at all, and produced an
      -- editor with zero language servers.
      --
      -- With it on, `lsp_setup` uses `vim.lsp.config` + `vim.lsp.enable` --
      -- Neovim's own mechanism, and the one `user.unity_lsp` already relies on.
      -- It also makes AstroLSP apply its `capabilities` and `flags` globally via
      -- `vim.lsp.config("*", ...)`, which it otherwise skips entirely -- so this
      -- is also what makes `astrolsp.lua`'s settings reach anything.
      --
      -- Upstream marks it `_EXPERIMENTAL_` and plans to delete the flag by
      -- making it unconditional (see AstroLSP's v4 roadmap notes). On Neovim
      -- 0.12 it is the only path that works.
      native_lsp_config = true,

      handlers = {
        -- WITH THE BRIDGE IN PLACE, THESE FINALLY MEAN SOMETHING. Each one is a
        -- second tool doing a job something else already does -- see
        -- `python-lsp.lua` and `astrolsp.lua` for the general argument.

        -- `stylua` ships an LSP mode, `nvim-lspconfig` has an `lsp/stylua.lua`,
        -- and Mason installed the binary for none-ls -- so `automatic_enable`
        -- was starting it as a language server too. Both it and none-ls
        -- advertise `textDocument/formatting` on every Lua buffer:
        --
        --     stylua           formatting=true
        --     null-ls          formatting=true   (source: stylua)
        --
        -- Harmless while format-on-save was dead. The moment the bridge revives
        -- it, that is two formatters on one buffer -- the fight `astrolsp.lua`
        -- opens by warning about. none-ls keeps the job: it is the one that
        -- reads `.stylua.toml` alongside every other none-ls source.
        stylua = false,
      },
    },
  },

  -- WHY `User AstroLspSetup` AND NOT `on_load("mason-lspconfig.nvim")`.
  --
  -- The obvious hook is the one AstroNvim itself uses,
  -- `astrocore.on_load("mason-lspconfig.nvim", ...)`. It fires too early:
  -- Mason's registry is not populated at that point, so
  -- `get_installed_package_names()` comes back empty, the bridge configures
  -- nothing, and -- because `automatic_enable` is off -- *no server starts at
  -- all*. That failure is quiet and total; the symptom is an editor with no
  -- language server anywhere and nothing in `:messages`.
  --
  -- `AstroLspSetup` is fired by AstroNvim's own lspconfig config after it has
  -- finished with mason-lspconfig, which is late enough for the registry to
  -- answer. It is also the hook `python-lsp.lua` already uses to register
  -- pyrefly, for the same reason.
  {
    "AstroNvim/astrocore",
    ---@param opts AstroCoreOpts
    opts = function(_, opts)
      local autocmds = opts.autocmds or {}
      autocmds.astrolsp_mason_bridge = {
        {
          event = "User",
          pattern = "AstroLspSetup",
          desc = "Hand Mason's language servers to AstroLSP (mason-lspconfig v2 shim)",
          once = true,
          callback = function() require("user.lsp_bridge").setup() end,
        },
      }
      opts.autocmds = autocmds
    end,
  },
}
