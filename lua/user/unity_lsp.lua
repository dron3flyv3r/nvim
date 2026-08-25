-- Pointing `roslyn_ls` at the right Unity solution.
--
-- WHY THIS IS A MODULE AND NOT `astrolsp`'s `config` TABLE. It should have been
-- the latter -- that is what `config` is for, and it is where `python-lsp.lua`
-- puts basedpyright's settings. It does not work in this config, and the reason
-- is worth writing down because it is not visible from any one file:
--
--   * AstroNvim v5 bridges AstroLSP to **mason-lspconfig v1**. Its
--     `plugins/lspconfig.lua` pins `version = "^1"` and passes
--     `handlers = { function(server) require("astrolsp").lsp_setup(server) end }`,
--     which is the v1 hook that ran AstroLSP for each installed server.
--   * The plugin actually installed here is **v2** (`mason-org/...`, pulled in
--     by `astrocommunity.pack.lua`). v2 dropped `handlers` entirely in favour
--     of `automatic_enable`, which calls `vim.lsp.enable()` directly.
--   * So `astrolsp.lsp_setup` is never called for a Mason-installed server.
--     `astrolsp.config.servers` is empty, `astrolsp.lsp_config(name)` never
--     runs, and therefore AstroLSP's `config.<server>` table is never handed to
--     `vim.lsp.config`.
--
-- The observable version, in a scratch Python buffer:
--
--     :lua =vim.tbl_map(function(c) return c.name end, vim.lsp.get_clients())
--     { "basedpyright", "pyrefly", "pyright", "ruff" }
--
-- ...`pyright` included, despite `handlers = { pyright = false }`. And
-- `astrolsp.attached_clients` is `{}`, which means AstroLSP's `on_attach` never
-- runs either. See the note at the bottom of `plugins/unity.lua` -- fixing that
-- properly is a change to every language in this config, not a Unity one.
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

      local unity = require("user.unity").root(bufnr)
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

        local unity = require "user.unity"
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
      -- generators). `<Leader>Ue` pulls that ground truth into the quickfix
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

return M
