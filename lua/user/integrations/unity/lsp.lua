-- Pointing `roslyn_ls` at the right Unity solution.
--
-- WHY THIS IS A MODULE AND NOT `astrolsp`'s `config` TABLE. `config` is the
-- right place for a server's *settings*, and it is where `python-lsp.lua` puts
-- basedpyright's. It cannot carry the two things below, because both have to be
-- registered before AstroLSP has been configured at all -- see the timing note
-- on `M.enable`. So `settings` could live there; `root_dir` and `on_init`
-- could not, and splitting one server's configuration across two files is
-- worse than keeping it whole.
--
-- ── A CORRECTION, AND WHY IT MATTERS ────────────────────────────────────────
--
-- This header used to claim that mason-lspconfig **v2** was installed, that its
-- `automatic_enable` had replaced v1's `handlers`, and that therefore
-- `astrolsp.lsp_setup` was never called for any Mason-installed server. All
-- three are false, and the belief is what hid the actual C# bug for so long --
-- if the bridge is broken for everything, a dead C# server looks like a symptom
-- rather than its own problem. MEASURED:
--
--   * The plugin on disk is **v1.32.0**. AstroNvim's `plugins/lspconfig.lua`
--     pins `version = "^1"`, and a version pin beats a spec URL: the repository
--     is `mason-org/...` (from `astrocommunity.pack.lua`) checked out at a v1
--     tag. `lua/mason-lspconfig/` has no `automatic_enable` in it anywhere.
--   * v1's `handlers` contract is therefore live, and AstroNvim drives it. In a
--     Python buffer:
--
--         :lua =vim.tbl_map(function(c) return c.name end, vim.lsp.get_clients())
--         { "basedpyright", "ruff", "pyrefly" }
--         :lua =vim.tbl_keys(require("astrolsp").attached_clients)
--         { 1 }
--
--     ...`pyright` correctly absent, so `handlers = { pyright = false }` is
--     being honoured, and `attached_clients` non-empty, so `on_attach` runs.
--
-- What IS broken is narrower and specific to C#: v1's package-name table has no
-- entry for `roslyn-language-server`, so this one server is never handed to
-- AstroLSP by anything. `M.enable` at the bottom is that missing hand-off.
-- (`user.lsp_bridge` was written against the v2 story above and is a no-op
-- under v1 -- its own header needs the same correction.)
--
-- `vim.lsp.config(name, cfg)` is Neovim's own mechanism and works regardless:
-- it stores the override, and the server's `lsp/roslyn_ls.lua` from
-- `nvim-lspconfig`'s runtime path is merged *under* it when the config is
-- resolved. Called from a plugin `init`, that is long before the first `cs`
-- buffer's `FileType`, which is when resolution happens.

local M = {}

--- Which solution to open, and where the workspace root is.
---
--- ── THE ROOT ────────────────────────────────────────────────────────────────
---
--- `nvim-lspconfig` roots the server at the nearest ancestor holding a `.sln`,
--- falling back to a `.csproj`. That is right for a normal .NET repository and
--- wrong for a Unity project, and `~/git/display_master` shows why: it has a
--- hand-written solution committed inside the assets tree.
---
---     Assets/Display.sln
---     Assets/Dependencies.csproj
---
--- Every script under `Assets/` -- which is every script -- therefore rooted the
--- server at `Assets/` and loaded `Display.sln`, a solution that does not
--- contain `Assembly-CSharp` and has never heard of `UnityEngine`. Nothing
--- errors. Completion inside Unity's own API just comes back empty, and
--- go-to-definition on `MonoBehaviour` goes nowhere.
---
--- ── THE SOLUTION FILE ───────────────────────────────────────────────────────
---
--- Once rooted correctly there is a second choice to make, because upstream
--- opens whichever `.sln` `vim.fs.dir` yields first and a Unity project root
--- collects them. `~/git/display_master` again:
---
---     display_master.sln   <- the live one, named after the project folder
---     display.sln          <- stale, from before the folder was renamed
---     GodotDisplay.sln     <- a different engine entirely
---
--- `user.unity.solution` picks deliberately; see it for how.
function M.setup()
  vim.lsp.config("roslyn_ls", {
    root_dir = function(bufnr, on_dir)
      local name = vim.api.nvim_buf_get_name(bufnr)

      -- Decompiled sources -- `/tmp/MetadataAsSource/.../Console.cs`, where
      -- `grd` on a symbol from a DLL lands. They belong to the client that
      -- sent you there, not to a project of their own; without this they get a
      -- second server rooted in `/tmp`. Upstream does the same thing, and
      -- replacing `root_dir` replaced it.
      if name:find "[/\\]MetadataAsSource[/\\]" then
        local previous = vim.fn.bufnr "#"
        local clients = vim.lsp.get_clients {
          name = "roslyn_ls",
          bufnr = previous ~= -1 and previous or nil,
        }
        if clients[1] then on_dir(clients[1].config.root_dir) end
        return
      end

      local unity = require("user.integrations.unity").root(bufnr)
      if unity then
        on_dir(unity)
        return
      end

      -- Not Unity: upstream's rule, solution first and then project.
      local found = vim.fs.root(bufnr, function(entry) return entry:match "%.slnx?$" ~= nil end)
        or vim.fs.root(bufnr, function(entry) return entry:match "%.csproj$" ~= nil end)
      if found then on_dir(found) end
    end,

    -- One element, replacing upstream's one element: `vim.lsp.config` merges
    -- with `tbl_deep_extend("force", ...)`, so index 1 is overwritten rather
    -- than appended to. That is deliberate -- two `solution/open`
    -- notifications would load two workspaces.
    on_init = {
      function(client)
        local root = client.config.root_dir
        if not root then return end

        local unity = require "user.integrations.unity"
        -- `root` is the Unity root whenever `root_dir` above found one, but ask
        -- rather than assume: this same server also attaches to ordinary C#
        -- projects, and this hook has to keep working for them.
        local project = unity.root(root)
        local solution = project and unity.solution(project)

        if not solution then
          for entry, type in vim.fs.dir(root) do
            if type == "file" and (vim.endswith(entry, ".sln") or vim.endswith(entry, ".slnx")) then
              solution = vim.fs.joinpath(root, entry)
              break
            end
          end
        end

        if solution then
          client:notify("solution/open", { solution = vim.uri_from_fname(solution) })
          return
        end

        -- No solution anywhere -- open the loose projects instead.
        local projects = {}
        for entry, type in vim.fs.dir(root) do
          if type == "file" and vim.endswith(entry, ".csproj") then
            table.insert(projects, vim.uri_from_fname(vim.fs.joinpath(root, entry)))
          end
        end
        if not vim.tbl_isempty(projects) then client:notify("project/open", { projects = projects }) end
      end,
    },

    -- THE NAME MASON INSTALLS THE BINARY UNDER.
    --
    -- `nvim-lspconfig`'s `lsp/roslyn_ls.lua` runs `Microsoft.CodeAnalysis.
    -- LanguageServer` -- the executable's name *inside* the nuget package,
    -- which its header tells you to extract and put on `$PATH` by hand. Mason
    -- installs that exact binary, but links it under the package's own name:
    --
    --     mason/bin/roslyn-language-server
    --       -> .store/.../tools/net10.0/linux-x64/Microsoft.CodeAnalysis.LanguageServer
    --
    -- So the server is installed and working, under a name upstream's `cmd`
    -- does not use, and nothing called `Microsoft.CodeAnalysis.LanguageServer`
    -- is on `$PATH`. MEASURED -- `vim.lsp.enable "roslyn_ls"` with upstream's
    -- `cmd` on a `.cs` buffer:
    --
    --     :lua =vim.tbl_map(function(c) return c.name end, vim.lsp.get_clients())
    --     {}
    --
    -- ...and nothing in `:messages` or `:LspLog`, because a `cmd` that is not
    -- executable is not an error Neovim reports at the point you would look.
    --
    -- Mason puts its `bin/` on Neovim's `$PATH`, so the bare name resolves.
    -- Six elements replacing upstream's six, for the reason `on_init` below
    -- gives: `vim.lsp.config` overwrites list entries by index rather than
    -- appending, so a shorter list would leave upstream's tail behind.
    cmd = {
      "roslyn-language-server",
      -- Both of these are required by the server -- it exits immediately
      -- without them, which is the other way this `cmd` goes quiet.
      "--logLevel",
      "Information",
      "--extensionLogDirectory",
      vim.fs.joinpath(vim.uv.os_tmpdir(), "roslyn_ls/logs"),
      "--stdio",
    },

    -- STOPPING MSBUILD FROM LEAVING A FLEET BEHIND.
    --
    -- Roslyn runs a design-time MSBuild build to learn what is in each project,
    -- and MSBuild's default is `nodeReuse:true` -- worker processes stay alive
    -- after the build so the next one starts faster. They are children of the
    -- language server, so when Neovim exits they are orphaned rather than
    -- reaped, and the next session starts a fresh set.
    --
    -- Measured on this machine, mid-session:
    --
    --     44 orphaned dotnet processes, 11.1 GB resident, 88% CPU
    --
    -- ...of which 42 were MSBuild node-reuse workers in two batches from two
    -- earlier Neovim sessions, at ~110 MB each. That is the "extremely laggy,
    -- pretty much useless" state, and no amount of tuning inside Neovim fixes
    -- it, because by then the load is not Neovim's.
    --
    -- One environment variable stops the leak at the source. The cost is a
    -- slower first design-time build per session, which is invisible next to
    -- the alternative.
    cmd_env = { MSBUILDDISABLENODEREUSE = "1" },

    -- ONE UPSTREAM HANDLER, REPAIRED FOR NEOVIM 0.12.
    --
    -- `nvim-lspconfig`'s `roslyn_ls.lua` answers
    -- `workspace/projectInitializationComplete` -- the notification roslyn
    -- sends once it has finished loading the solution -- by re-pulling
    -- diagnostics for every attached buffer, because the ones it published
    -- while the workspace was still loading are incomplete. It does that
    -- through `vim.lsp.util._refresh`, which does not exist on 0.12:
    --
    --     .../lsp/roslyn_ls.lua:54: attempt to call field '_refresh' (a nil value)
    --
    -- Private function, so its removal is not a breaking change and no
    -- deprecation warned about it -- it moved to `vim.lsp.diagnostic._refresh`,
    -- which is what `vim/lsp/handlers.lua` itself now calls. The visible cost
    -- of leaving it: an error traceback on **every** solution load, and the
    -- stale mid-load diagnostics are never replaced -- so a file reads as
    -- clean, or as broken, on evidence from before roslyn knew what was in the
    -- project. On a Unity solution that window is tens of seconds.
    --
    -- Only this one key is replaced; `vim.lsp.config` merges per key, so
    -- upstream's other handlers (the `dotnet restore` prompts, the Razor
    -- warning) are left alone.
    handlers = {
      ["workspace/projectInitializationComplete"] = function(_, _, ctx)
        vim.notify("Roslyn project initialization complete", vim.log.levels.INFO, { title = "roslyn_ls" })

        -- Guarded because this is a private function too, and the whole point
        -- of this block is that they move: a future rename should cost the
        -- diagnostic refresh, not throw from inside a notification handler.
        local refresh = vim.lsp.diagnostic._refresh
        if not refresh then return end
        for _, buf in ipairs(vim.lsp.get_buffers_by_client_id(ctx.client_id)) do
          pcall(refresh, buf, ctx.client_id)
        end
      end,
    },

    settings = {
      -- THE AUTO-IMPORT SETTING. This is what makes `Vector3` complete in a
      -- file with no `using UnityEngine;` and add the using when you accept
      -- it. It is also upstream's default -- restated here because it is the
      -- specific behaviour this whole file exists to make work, and a future
      -- reader deleting "redundant" settings should know which one is load
      -- bearing.
      ["csharp|completion"] = {
        dotnet_show_completion_items_from_unimported_namespaces = true,
        dotnet_show_name_completion_suggestions = true,
        dotnet_provide_regex_completions = true,
      },

      -- `openFiles`, NOT upstream's `fullSolution`.
      --
      -- `fullSolution` analyses every project in the background, which is a
      -- reasonable default for a repository with three or four projects in it.
      -- A Unity solution has sixty-odd -- `Assembly-CSharp`,
      -- `Assembly-CSharp-Editor`, one per assembly definition, and one per
      -- package including every `Unity.*` and `UnityEditor.*` the project pulls
      -- in. Analysing all of them means a design-time MSBuild build of all of
      -- them, which is where the process fleet described above comes from, and
      -- the CPU never really settles.
      --
      -- WHAT YOU GIVE UP: an error in a file you have not opened. That is a
      -- smaller loss here than it looks, because Unity compiles the whole
      -- project itself on every refresh and knows things Roslyn does not
      -- (assembly definition boundaries, IL post-processors, source
      -- generators). The contextual Problems action pulls that ground truth into quickfix
      -- list -- see `user.unity_log`. Roslyn covers the file you are in;
      -- Unity covers the project.
      --
      -- If you want the old behaviour on a small project, this is the knob.
      ["csharp|background_analysis"] = {
        dotnet_analyzer_diagnostics_scope = "openFiles",
        dotnet_compiler_diagnostics_scope = "openFiles",
      },
    },
  })
end

--- Actually start the thing. `M.setup` only *registers* a configuration.
---
--- ── WHY THIS IS NEEDED AT ALL ────────────────────────────────────────────────
---
--- Every other server in this config is enabled by mason-lspconfig, which walks
--- Mason's installed packages and hands each one to AstroLSP. It never hands it
--- `roslyn_ls`, and the reason is a mapping table:
---
---   * AstroNvim's `plugins/lspconfig.lua` pins `version = "^1"`, so the plugin
---     on disk is **v1.32.0** -- despite the spec URL being `mason-org/...` and
---     despite the note at the top of this file, which had it backwards. v1 is
---     also the version whose `handlers` contract AstroNvim drives, so this half
---     of the config works: `basedpyright`, `ruff` and `lua_ls` all attach.
---   * v1 translates a Mason package name to an lspconfig server name through
---     `mason-lspconfig/mappings/server.lua`, a hand-written table of 224
---     entries. For C# it knows `omnisharp`, `omnisharp-mono` and
---     `csharp-language-server`. `roslyn-language-server` is newer than v1 and
---     **is not in it** -- so the package is installed, and as far as
---     mason-lspconfig is concerned it maps to no server at all.
---
--- MEASURED, on a `.cs` buffer with a `.csproj` beside it:
---
---     :lua =vim.tbl_map(function(c) return c.name end, vim.lsp.get_clients())
---     {}                                  -- and `{ "basedpyright", ... }` in Python
---
--- Nothing errors. `cs` is the right filetype, the parser is built, the server
--- is installed, its configuration is registered -- and no client starts,
--- because no code path ever calls `vim.lsp.enable "roslyn_ls"`.
---
--- (`user.lsp_bridge` was written to close this gap and cannot: it asks v2 for
--- the same map, `require "mason-lspconfig.mappings"` does not exist in v1, and
--- its `pcall` turns that into an empty server list. It is a no-op today, which
--- is why nothing it says about `handlers` is observable either.)
---
--- ── WHY `lsp_setup` AND NOT `vim.lsp.enable` ─────────────────────────────────
---
--- `vim.lsp.enable` would start the server and stop there. Going through
--- AstroLSP is what applies the rest of this config to it: `on_attach`, and
--- therefore `astrolsp.lua`'s `gd` / `gy` / `<Leader>lk` pickers -- the ones
--- whose comments are written about roslyn specifically -- plus format-on-save
--- and `<Leader>uY`. With `native_lsp_config = true` (set in
--- `plugins/lsp-bridge.lua`) `lsp_setup` enables through `vim.lsp.config` and
--- `vim.lsp.enable` underneath, so the configuration registered by `M.setup`
--- still applies, merged under AstroLSP's own.
---
--- ── WHY `AstroLspSetup` AND NOT `M.setup` ────────────────────────────────────
---
--- `M.setup` runs in a plugin `init`, at startup, which is deliberately early --
--- a configuration has to be registered before the first `cs` buffer's
--- `FileType`. AstroLSP is not configured yet at that point, so `lsp_setup`
--- would read `native_lsp_config` as nil and take the pre-0.11 `lspconfig` path,
--- which registers nothing and starts nothing, silently. `AstroLspSetup` fires
--- once the other servers are set up, and is the hook `python-lsp.lua` already
--- uses to register pyrefly for the same reason.
function M.enable()
  -- Installed via Mason (`plugins/unity.lua` asks for it), but this file should
  -- not start a server that is not there: `vim.lsp.enable` on a `cmd` that does
  -- not exist warns at every matching `FileType` from then on.
  if vim.fn.executable "roslyn-language-server" ~= 1 then return end

  local ok, astrolsp = pcall(require, "astrolsp")
  if not ok then return end
  astrolsp.lsp_setup "roslyn_ls"

  -- `vim.lsp.enable` only re-runs `FileType` for already-open buffers once
  -- `VimEnter` has fired. Opening Neovim *on* a `.cs` file can get here first,
  -- and that buffer would sit with no server until you touched another one.
  -- Same kick as `python-lsp.lua` and `user.lsp_bridge` use, and a no-op when
  -- there is nothing to start.
  vim.schedule(function() pcall(vim.cmd.doautoall, "nvim.lsp.enable FileType") end)
end

return M
