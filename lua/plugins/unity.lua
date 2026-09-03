local filetypes = {
  extension = {
    unity = "yaml",
    prefab = "yaml",
    asset = "yaml",
    mat = "yaml",
    anim = "yaml",
    controller = "yaml",
    overrideController = "yaml",
    physicsMaterial = "yaml",
    physicsMaterial2D = "yaml",
    meta = "yaml",
    asmdef = "json",
    asmref = "json",
    shader = "hlsl",
    compute = "hlsl",
    cginc = "hlsl",
    hlsl = "hlsl",
    uxml = "xml",
    uss = "css",
  },
}

---@type LazySpec
return {
  {
    "neovim/nvim-lspconfig",
    optional = true,
    init = function() require("user.integrations.unity.lsp").setup() end,
  },

  {
    "mason-org/mason-lspconfig.nvim",
    optional = true,
    opts = function(_, opts)
      -- `automatic_enable = false` (nothing sets it today, but if anything ever
      -- does) means nothing is auto-enabled and there is nothing to exclude.
      -- Writing a table over that would switch the whole feature back on.
      if opts.automatic_enable == false then return end
      if type(opts.automatic_enable) ~= "table" then opts.automatic_enable = {} end
      opts.automatic_enable.exclude =
        require("astrocore").list_insert_unique(opts.automatic_enable.exclude or {}, { "omnisharp", "csharp_ls" })
    end,
  },

  -- Belt to those braces: if the mason-lspconfig bridge described in
  -- `user.integrations.unity.lsp` is ever repaired, this is the lever that will then matter.
  {
    "AstroNvim/astrolsp",
    ---@type AstroLSPOpts
    opts = { handlers = { omnisharp = false, csharp_ls = false } },
  },

  {
    "WhoIsSethDaniel/mason-tool-installer.nvim",
    opts = function(_, opts)
      opts.ensure_installed = require("astrocore").list_insert_unique(opts.ensure_installed, {
        "roslyn-language-server",

        "tree-sitter-cli",
      })
    end,
  },

  {
    "nvim-treesitter/nvim-treesitter",
    opts = function(_, opts)
      -- `hlsl` for what is inside a `.shader`'s program blocks; there is no
      -- ShaderLab parser to install.
      opts.ensure_installed = require("astrocore").list_insert_unique(opts.ensure_installed, { "c_sharp", "hlsl" })
    end,
  },

  {
    "mfussenegger/nvim-dap",
    optional = true,
    init = function()
      vim.api.nvim_create_autocmd("User", {
        pattern = "LazyLoad",
        desc = "Register the Unity debug adapter once nvim-dap is loaded",
        callback = function(args)
          if args.data ~= "nvim-dap" then return end
          require("user.integrations.unity.dap").setup()
          return true -- one-shot; delete the autocmd
        end,
      })
    end,
  },

  {
    "AstroNvim/astrocore",
    ---@param opts AstroCoreOpts
    opts = function(_, opts)
      local actions = require "user.integrations.unity.actions"
      opts.filetypes = require("astrocore").extend_tbl(opts.filetypes or {}, filetypes)
      local autocmds = opts.autocmds or {}
      autocmds.unity_roslyn = {
        {
          event = "User",
          pattern = "AstroLspSetup",
          desc = "Start roslyn (mason-lspconfig v1 has no mapping for it)",
          once = true,
          callback = function() require("user.integrations.unity.lsp").enable() end,
        },
      }
      autocmds.unity_project = {
        {
          event = { "BufReadPost", "BufNewFile" },
          desc = "Listen for Unity's open-this-file requests in this project",
          callback = function(args)
            local root = require("user.integrations.unity").root(args.buf)
            -- Cheap and idempotent: `register` returns early when another
            -- Neovim already owns the socket.
            if root then require("user.integrations.unity.shim").register(root) end
          end,
        },
        {
          event = "BufWritePost",
          pattern = "*.cs",
          desc = "Warn when a MonoBehaviour's class name does not match its file name",
          callback = function(args) require("user.integrations.unity.assets").check_class_name(args.buf) end,
        },
      }
      opts.autocmds = autocmds

      local maps = assert(opts.mappings)
      maps.n["<Leader>U"] = { desc = "Unity" }
      maps.n["<Leader>Up"] = { actions.play, desc = "Enter Play mode" }
      maps.n["<Leader>Us"] = { actions.stop, desc = "Stop Play mode" }
      maps.n["<Leader>Ur"] = { actions.restart, desc = "Restart Play mode" }
      maps.n["<Leader>Ub"] = { actions.refresh, desc = "Refresh assets and recompile" }
      maps.n["<Leader>Ut"] = { actions.test_cursor, desc = "Run test under cursor" }
      maps.n["<Leader>UT"] = { actions.test_edit, desc = "Choose EditMode test" }
      maps.n["<Leader>Ua"] = { actions.attach, desc = "Attach debugger" }
      maps.n["<Leader>Ue"] = { actions.errors, desc = "Compiler errors" }
      maps.n["<Leader>Uw"] = { actions.warnings, desc = "Compiler errors and warnings" }
      maps.n["<Leader>Ul"] = { actions.log, desc = "Follow editor log" }
      maps.n["<Leader>Ud"] = { actions.docs, desc = "Documentation for symbol" }
      maps.n["<Leader>Ui"] = { actions.status, desc = "Integration status" }

      opts.commands = opts.commands or {}
      opts.commands.UnityShim = {
        function() require("user.integrations.unity.shim").install() end,
        desc = "Install the shim that makes Unity treat Neovim as its script editor",
      }
      opts.commands.UnityStatus = {
        function() require("user.integrations.unity.shim").status() end,
        desc = "Report which parts of the Unity integration are live",
      }
      opts.commands.UnityAttach = {
        function() require("user.integrations.unity.dap").attach() end,
        desc = "Attach the debugger to a running Unity editor",
      }
      opts.commands.UnityTests = {
        function(args) require("user.integrations.unity.tests").pick(args.args ~= "" and args.args or "EditMode") end,
        desc = "Pick and run a Unity test",
        nargs = "?",
        complete = function() return require("user.integrations.unity.tests").MODES end,
      }
      opts.commands.UnityErrors = {
        function(args) require("user.integrations.unity.log").errors(args.bang) end,
        desc = "Unity's compiler diagnostics into the quickfix list (! for warnings too)",
        bang = true,
      }
    end,
  },

  -- The `.meta` half of `user.integrations.unity.assets`. Same hook as
  -- `plugins/lsp-file-events.lua` uses, for the same reason: neo-tree is where
  -- files get moved, and it is the only place that knows a rename happened.
  {
    "nvim-neo-tree/neo-tree.nvim",
    optional = true,
    opts = function(_, opts)
      local assets = require "user.integrations.unity.assets"
      opts.event_handlers = opts.event_handlers or {}
      vim.list_extend(opts.event_handlers, {
        { event = "file_deleted", handler = function(path) assets.deleted(path) end },
        { event = "file_moved", handler = function(args) assets.moved(args.source, args.destination) end },
        { event = "file_renamed", handler = function(args) assets.moved(args.source, args.destination) end },
      })
      return opts
    end,
  },
}
