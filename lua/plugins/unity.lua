-- Unity: C# completion and auto-import, a debugger that attaches to the running
-- editor, and enough remote control that you do not have to alt-tab to press
-- Play.
--
-- WHAT GOES WHERE. This file is only the wiring; every decision that needed
-- explaining is in the module it belongs to:
--
--   user.unity            what counts as a project, and which .sln to open
--   user.unity_editor     which Unity processes are running, and on what ports
--   user.unity_dap        the Mono debug adapter, and attaching to the editor
--   user.unity_messenger  the UDP protocol Unity's own IDE packages speak
--   user.unity_tests      Unity Test Framework runs, failures into quickfix
--   user.unity_log        Unity's compiler errors into quickfix
--   user.unity_assets     .meta companions, and the class-name/file-name rule
--   user.unity_docs       the Scripting Reference for the symbol under cursor
--   user.unity_shim       making Unity accept Neovim as its script editor
--
-- ── The language server ──────────────────────────────────────────────────────
--
-- THREE C# SERVERS ARE INSTALLED IN MASON on this machine -- `omnisharp`,
-- `csharp-language-server` and `roslyn-language-server` -- and
-- `mason-lspconfig` enables everything it finds for a filetype
-- (`filetype_mappings.lua` maps `cs` to all three). Left alone, opening a Unity
-- script starts all three: three sets of diagnostics, three completion lists
-- merged into one menu, and three MSBuild workspaces loading a sixty-project
-- solution at once. Two of them are switched off below, for the same reason
-- `python-lsp.lua` switches off pyright: one tool per job.
--
-- WHY ROSLYN IS THE ONE THAT STAYS. It is the server Visual Studio and the C#
-- Dev Kit are built on, and the difference shows up precisely where this
-- config's request list points:
--
--   * AUTO-IMPORT. `dotnet_show_completion_items_from_unimported_namespaces`
--     is what makes `Vector3` complete in a file with no `using UnityEngine;`
--     and add the using when you accept it. OmniSharp's equivalent is
--     off-by-default, unreliable across Unity's assembly boundaries, and does
--     not exist at all in csharp-language-server.
--   * COMPLETION QUALITY. Roslyn is the compiler's own API surface, so it
--     resolves through Unity's generic serialisation helpers and
--     `GetComponent<T>()` where the others return `Unknown` and therefore
--     offer nothing.
--   * `nvim-lspconfig` ships a real `roslyn_ls` config (solution loading, the
--     nested and fix-all code action commands, decompiled-source navigation),
--     so none of that has to be written here.
--
-- FORMATTING is Roslyn's too, and there is deliberately no csharpier or
-- dotnet-format in the mix: Roslyn reads the project's `.editorconfig`, which
-- is the file the rest of the team's Rider installs read as well. Adding a
-- second formatter is how the fight described in `astrolsp.lua` starts.
--
-- ── What is NOT here ─────────────────────────────────────────────────────────
--
-- Building a player. That needs a `-executeMethod` entry point that is specific
-- to each project's build script, so it belongs in that project's justfile
-- where `<Leader>rr` (see `plugins/tasks.lua`) will find it -- not in a config
-- that cannot know the method's name.

--- Unity's own files, and what to treat them as.
---
--- Scenes, prefabs and every `.asset` are YAML -- Unity's own flavour of it,
--- with `!u!114` tags a strict parser rejects, but close enough that folds and
--- highlighting work and a hand edit is survivable. AstroNvim's `large_buf`
--- feature is what keeps a 40 MB scene from being highlighted at all.
---
--- `.asmdef` and `.asmref` are plain JSON and benefit from it: an assembly
--- definition is mostly a list of references you edit by hand.
---
--- Shaders are the interesting case. A `.shader` is ShaderLab -- Unity's own
--- surrounding syntax -- with HLSL inside the `CGPROGRAM` / `HLSLPROGRAM`
--- blocks, and there is no ShaderLab parser anywhere. `hlsl` is the closest
--- thing that exists, and it is right for the part of the file you actually
--- write code in.
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

--- `<Leader>U` -- the Unity keys.
---
--- A prefix of its own rather than hanging off `<Leader>d` (AstroNvim's
--- debugger) or `<Leader>r` (run), because only one of these is debugging and
--- none of them is a task: they are messages to another process. Attaching the
--- debugger is here too, next to the things you press around it, and the
--- ordinary `<Leader>d` keys still drive the session once it is running.
---@param maps table
local function mappings(maps)
  local function unity(fn)
    return function()
      local root = require("user.unity").require_root()
      if root then fn(root) end
    end
  end

  --- A mapping that sends one message to the editor holding this project open.
  ---@param type_name string A key of `user.unity_messenger`'s `TYPE`.
  ---@param said string What to say once it is on its way.
  ---@param desc string The which-key entry.
  local function message(type_name, said, desc)
    return {
      unity(function(root)
        local editors = require "user.unity_editor"
        local instance = editors.require_for_project(root)
        if not instance then return end
        local messenger = require "user.unity_messenger"
        messenger.send_checked(
          instance,
          messenger.TYPE[type_name],
          nil,
          function() vim.notify(said, vim.log.levels.INFO, { title = "Unity" }) end
        )
      end),
      desc = desc,
    }
  end

  maps.n["<Leader>U"] = { desc = "󰚯 Unity" }

  -- Debugging. `<Leader>Ua` attaches; everything after that is AstroNvim's
  -- `<Leader>d` keys -- `<Leader>db` to breakpoint, `<Leader>do`/`di` to step.
  maps.n["<Leader>Ua"] = { function() require("user.unity_dap").attach() end, desc = "Attach debugger to Unity" }

  -- Play mode. Note that Play tears down Unity's message socket on its way in
  -- and rebinds it after the domain reload, so Stop within a second of Play can
  -- land on nothing -- see `user.unity_messenger`.
  maps.n["<Leader>Up"] = message("Play", "Entering play mode", "Play")
  maps.n["<Leader>Us"] = message("Stop", "Leaving play mode", "Stop play mode")
  -- Not `message()`: a restart is two messages with a wait between them that
  -- has to be observed rather than guessed. See `user.unity_play`.
  maps.n["<Leader>UR"] = {
    unity(function(root)
      local instance = require("user.unity_editor").require_for_project(root)
      if instance then require("user.unity_play").restart(instance) end
    end),
    desc = "Restart play mode (stop, then play)",
  }
  maps.n["<Leader>Uz"] = message("Pause", "Paused", "Pause")
  maps.n["<Leader>UZ"] = message("Unpause", "Resumed", "Unpause")

  -- The one that earns the whole messaging channel: Unity only notices your
  -- edits when its window regains focus, so a save in Neovim normally means
  -- alt-tab, wait, alt-tab back. This recompiles without moving.
  maps.n["<Leader>Ur"] = message("Refresh", "Refreshing assets", "Refresh assets (recompile)")

  -- Unity's own compiler output, which knows about asmdef boundaries and source
  -- generators that the language server's stale csproj files do not.
  maps.n["<Leader>Ue"] =
    { function() require("user.unity_log").errors() end, desc = "Unity compile errors to quickfix" }
  maps.n["<Leader>UE"] = {
    function() require("user.unity_log").errors(true) end,
    desc = "Unity errors + warnings to quickfix",
  }
  maps.n["<Leader>Ul"] = { function() require("user.unity_log").tail() end, desc = "Tail Unity's editor log" }

  -- Tests. EditMode on the plain keys because that is the fast one; PlayMode
  -- enters play mode and takes seconds, so it is spelled out.
  maps.n["<Leader>Ut"] = {
    function() require("user.unity_tests").run_at_cursor "EditMode" end,
    desc = "Run test under cursor (EditMode)",
  }
  maps.n["<Leader>UT"] = { function() require("user.unity_tests").pick "EditMode" end, desc = "Pick a test (EditMode)" }
  maps.n["<Leader>Um"] = {
    function() require("user.unity_tests").pick "PlayMode" end,
    desc = "Pick a test (PlayMode)",
  }

  maps.n["<Leader>Ud"] = { function() require("user.unity_docs").open() end, desc = "Unity docs for symbol" }
  maps.n["<Leader>Ui"] = { function() require("user.unity_shim").status() end, desc = "Unity integration status" }
end

---@type LazySpec
return {
  -- ── Language server ───────────────────────────────────────────────────────
  --
  -- `roslyn_ls` needs telling which solution to open and where the project root
  -- is; both, and why AstroLSP's `config` table could not carry them, are in
  -- `user.unity_lsp`.
  --
  -- `init` rather than `config`: it runs at startup, and the override has to be
  -- registered before the first `cs` buffer's `FileType` -- which is when
  -- Neovim resolves a server's configuration and starts it.
  {
    "neovim/nvim-lspconfig",
    optional = true,
    init = function() require("user.unity_lsp").setup() end,
  },

  -- KEEPING THE OTHER TWO C# SERVERS OUT.
  --
  -- Three are installed in Mason on this machine -- `omnisharp`,
  -- `csharp-language-server` and `roslyn-language-server` -- and
  -- `mason-lspconfig/filetype_mappings.lua` maps `cs` to all three. Left alone,
  -- opening a Unity script started `csharp_ls` *and* `roslyn_ls`, both rooted
  -- in `Assets/`, both loading a workspace: two sets of diagnostics and two
  -- completion lists merged into one menu.
  --
  -- `automatic_enable` is where that decision is actually made -- AstroLSP's
  -- `handlers = { csharp_ls = false }` looks like the right lever and is dead
  -- code in this config; see `user.unity_lsp` for why.
  --
  -- WHY ROSLYN IS THE ONE THAT STAYS:
  --
  --   * AUTO-IMPORT. `dotnet_show_completion_items_from_unimported_namespaces`
  --     is what offers `Vector3` in a file with no `using UnityEngine;` and
  --     adds the using on accept. OmniSharp's equivalent is off by default and
  --     unreliable across Unity's assembly boundaries; csharp-language-server
  --     has none.
  --   * COMPLETION QUALITY. Roslyn is the C# compiler's own API surface, so it
  --     resolves through `GetComponent<T>()` and Unity's generic serialisation
  --     helpers where the others give up and return `Unknown` -- and an unknown
  --     type has no members, so the menu is empty rather than wrong.
  --   * `nvim-lspconfig` ships a real `roslyn_ls` config -- solution loading,
  --     the nested and fix-all code action commands, decompiled-source
  --     navigation -- so none of that has to be written here.
  --
  -- FORMATTING is Roslyn's too, and there is deliberately no csharpier or
  -- dotnet-format in the mix: Roslyn reads the project's `.editorconfig`, which
  -- is the same file the rest of the team's Rider installs read. A second
  -- formatter is how the fight described in `astrolsp.lua` starts.
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
  -- `user.unity_lsp` is ever repaired, this is the lever that will then matter.
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

        -- WHY A TREESITTER BUILD TOOL IS IN THE UNITY SPEC. nvim-treesitter's
        -- `main` branch does not ship prebuilt parsers and does not compile
        -- them itself -- it shells out to the `tree-sitter` CLI. That CLI was
        -- not installed on this machine, so *no* parser had ever been built:
        --
        --     :TSInstall c_sharp
        --     error: Error during "tree-sitter build": ENOENT (cmd): 'tree-sitter'
        --     [nvim-treesitter]: Installed 0/4 languages
        --
        -- ...which is why `~/.local/share/nvim/site/parser/` was empty and every
        -- filetype was falling back to regex syntax. It is listed here rather
        -- than in `treesitter.lua` because this spec is the one that adds
        -- parsers which are load-bearing for a feature (`c_sharp`, below, is
        -- what `unity_tests.test_at_cursor` and
        -- `unity_assets.check_class_name` are built on), so shipping the
        -- requirement with it keeps the two from drifting apart.
        --
        -- Mason puts its `bin/` on Neovim's `$PATH`, so nvim-treesitter finds
        -- it with no further wiring.
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

  -- ── Debugger ──────────────────────────────────────────────────────────────
  {
    "mfussenegger/nvim-dap",
    optional = true,
    -- WHY AN AUTOCMD AND NOT `config`. The adapter has to be registered before
    -- the first `dap.continue()`, or plain `<Leader>dc` offers no Unity entry
    -- and you have to know to press `<Leader>Ua` instead. But nvim-dap is
    -- configured by AstroNvim, and a `config` function here would *replace*
    -- that one rather than run alongside it. `User LazyLoad` fires once
    -- nvim-dap is actually loaded, whoever loaded it and however -- and
    -- `init` runs at startup, so the hook is in place before any of it.
    init = function()
      vim.api.nvim_create_autocmd("User", {
        pattern = "LazyLoad",
        desc = "Register the Unity debug adapter once nvim-dap is loaded",
        callback = function(args)
          if args.data ~= "nvim-dap" then return end
          require("user.unity_dap").setup()
          return true -- one-shot; delete the autocmd
        end,
      })
    end,
  },

  -- ── Everything else ───────────────────────────────────────────────────────
  {
    "AstroNvim/astrocore",
    ---@param opts AstroCoreOpts
    opts = function(_, opts)
      opts.filetypes = require("astrocore").extend_tbl(opts.filetypes or {}, filetypes)
      mappings(assert(opts.mappings))

      local autocmds = opts.autocmds or {}
      -- Starting roslyn. mason-lspconfig v1 -- which is what is on disk, see
      -- `user.unity_lsp.enable` -- has no mapping for `roslyn-language-server`,
      -- so it never hands the server to AstroLSP and nothing enables it. This
      -- is the one thing standing between a correctly configured C# server and
      -- a `.cs` buffer with no client attached.
      autocmds.unity_roslyn = {
        {
          event = "User",
          pattern = "AstroLspSetup",
          desc = "Start roslyn (mason-lspconfig v1 has no mapping for it)",
          once = true,
          callback = function() require("user.unity_lsp").enable() end,
        },
      }
      autocmds.unity_project = {
        {
          event = { "BufReadPost", "BufNewFile" },
          desc = "Listen for Unity's open-this-file requests in this project",
          callback = function(args)
            local root = require("user.unity").root(args.buf)
            -- Cheap and idempotent: `register` returns early when another
            -- Neovim already owns the socket.
            if root then require("user.unity_shim").register(root) end
          end,
        },
        {
          event = "BufWritePost",
          pattern = "*.cs",
          desc = "Warn when a MonoBehaviour's class name does not match its file name",
          callback = function(args) require("user.unity_assets").check_class_name(args.buf) end,
        },
      }
      opts.autocmds = autocmds

      opts.commands = opts.commands or {}
      opts.commands.UnityShim = {
        function() require("user.unity_shim").install() end,
        desc = "Install the shim that makes Unity treat Neovim as its script editor",
      }
      opts.commands.UnityStatus = {
        function() require("user.unity_shim").status() end,
        desc = "Report which parts of the Unity integration are live",
      }
      opts.commands.UnityAttach = {
        function() require("user.unity_dap").attach() end,
        desc = "Attach the debugger to a running Unity editor",
      }
      opts.commands.UnityTests = {
        function(args) require("user.unity_tests").pick(args.args ~= "" and args.args or "EditMode") end,
        desc = "Pick and run a Unity test",
        nargs = "?",
        complete = function() return require("user.unity_tests").MODES end,
      }
      opts.commands.UnityErrors = {
        function(args) require("user.unity_log").errors(args.bang) end,
        desc = "Unity's compiler diagnostics into the quickfix list (! for warnings too)",
        bang = true,
      }
    end,
  },

  -- The `.meta` half of `user.unity_assets`. Same hook as
  -- `plugins/lsp-file-events.lua` uses, for the same reason: neo-tree is where
  -- files get moved, and it is the only place that knows a rename happened.
  {
    "nvim-neo-tree/neo-tree.nvim",
    optional = true,
    opts = function(_, opts)
      local assets = require "user.unity_assets"
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
