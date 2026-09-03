local M = {}

function M.setup()
  vim.lsp.config("roslyn_ls", {
    root_dir = function(bufnr, on_dir)
      local name = vim.api.nvim_buf_get_name(bufnr)

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

    cmd_env = { MSBUILDDISABLENODEREUSE = "1" },

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
      ["csharp|completion"] = {
        dotnet_show_completion_items_from_unimported_namespaces = true,
        dotnet_show_name_completion_suggestions = true,
        dotnet_provide_regex_completions = true,
      },

      ["csharp|background_analysis"] = {
        dotnet_analyzer_diagnostics_scope = "openFiles",
        dotnet_compiler_diagnostics_scope = "openFiles",
      },
    },
  })
end

function M.enable()
  -- Installed via Mason (`plugins/unity.lua` asks for it), but this file should
  -- not start a server that is not there: `vim.lsp.enable` on a `cmd` that does
  -- not exist warns at every matching `FileType` from then on.
  if vim.fn.executable "roslyn-language-server" ~= 1 then return end

  local ok, astrolsp = pcall(require, "astrolsp")
  if not ok then return end
  astrolsp.lsp_setup "roslyn_ls"

  vim.schedule(function() pcall(vim.cmd.doautoall, "nvim.lsp.enable FileType") end)
end

return M
