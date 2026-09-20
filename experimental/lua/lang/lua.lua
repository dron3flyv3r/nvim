---@type lang.Module
return {
  ft = { "lua" },

  lsp = {
    lua_ls = {
      cmd = { "lua-language-server" },
      root_markers = { ".luarc.json", "stylua.toml", ".stylua.toml", ".git" },
      settings = {
        Lua = {
          workspace = { checkThirdParty = false },
          format = { enable = false },
          hint = { enable = true },
          telemetry = { enable = false },
        },
      },
    },
  },

  actions = {
    name = "Lua",
    priority = 50,

    detect = function(ctx)
      if ctx.filetype ~= "lua" then return false end
      if vim.startswith(ctx.file, vim.fn.stdpath "config" --[[@as string]]) then return "Neovim config" end
      return true
    end,

    actions = function(ctx)
      local in_config = vim.startswith(ctx.file, vim.fn.stdpath "config" --[[@as string]])
      return {
        {
          id = "source",
          label = "Source this file",
          category = "Run",
          repeatable = false,
          available = ctx.file ~= "" or "The buffer has no file to source",
          run = function() vim.cmd.source(ctx.file) end,
        },
        {
          id = "syntax",
          label = "Check syntax with luac",
          category = "Build",
          available = vim.fn.executable "luac" == 1 or "luac is not on PATH",
          run = function() vim.cmd.make() end,
        },
        {
          id = "restart_lsp",
          label = "Restart the Lua language server",
          category = "Maintenance",
          available = not vim.tbl_isempty(vim.lsp.get_clients { bufnr = ctx.bufnr })
            or "No language server is attached to this buffer",
          run = function() vim.cmd.LspRestart() end,
        },
        {
          id = "lsp_log",
          label = "Open the LSP log",
          category = "Inspect",
          repeatable = false,
          run = function() vim.cmd.tabedit(vim.lsp.log.get_filename()) end,
        },
        {
          id = "reload",
          label = "Reload this config module",
          category = "Maintenance",
          available = in_config or "Only config files under " .. vim.fn.stdpath "config" .. " can be reloaded",
          run = function()
            local module = ctx.file:match "/lua/(.*)%.lua$"
            if not module then error("Not a module under lua/: " .. ctx.file) end
            module = module:gsub("/", "."):gsub("%.init$", "")
            package.loaded[module] = nil
            require(module)
            vim.notify("Reloaded " .. module, vim.log.levels.INFO, { title = "Lua" })
          end,
        },
      }
    end,
  },
}
