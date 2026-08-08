-- lua/plugins/godot.lua
return {
  {
    -- dummy plugin to attach your init/config logic to
    "nvim-lua/plenary.nvim",

    init = function()
      -- start Neovim server only if we're in a Godot project
      local paths_to_check = { "/", "/../" }
      local is_godot_project = false
      local godot_project_path = ""
      local cwd = vim.fn.getcwd()

      for _, value in ipairs(paths_to_check) do
        if vim.uv.fs_stat(cwd .. value .. "project.godot") then
          is_godot_project = true
          godot_project_path = cwd .. value
          break
        end
      end

      if not is_godot_project then return end

      local pipe = godot_project_path .. "/server.pipe"
      local is_server_running = vim.uv.fs_stat(pipe)

      if not is_server_running then vim.fn.serverstart(pipe) end
    end,

    config = function()
      -- Godot LSP setup
      local ok, lspconfig = pcall(require, "lspconfig")
      if not ok then return end

      -- ensure netcat is installed on your system: e.g. `sudo pacman -S gnu-netcat`
      lspconfig.gdscript.setup {
        cmd = { "nc", "127.0.0.1", os.getenv "GDScript_Port" or "6005" },
        root_dir = lspconfig.util.root_pattern "project.godot",
      }

      -- LSP keymaps (including gd → go to definition)
      vim.api.nvim_create_autocmd("LspAttach", {
        callback = function(args)
          local bufnr = args.buf

          local function map(mode, lhs, rhs) vim.keymap.set(mode, lhs, rhs, { buffer = bufnr, silent = true }) end

          -- override Vim's built-in `gd` with LSP go-to-definition
          map("n", "gd", vim.lsp.buf.definition)
          -- add more if you want:
          -- map("n", "K", vim.lsp.buf.hover)
          -- map("n", "gr", vim.lsp.buf.references)
        end,
      })
    end,
  },
}
