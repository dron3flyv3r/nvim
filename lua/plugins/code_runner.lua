---@type LazySpec
return {
  "CRAG666/code_runner.nvim",
  dependencies = {
    "nvim-lua/plenary.nvim",
    { "AstroNvim/astroui", opts = { icons = { CodeRunner = "" } } },
    {
      "AstroNvim/astrocore",
      opts = function(_, opts)
        local maps = opts.mappings
        local prefix = "<leader>r"
        local icon = require("astroui").get_icon("CodeRunner", 1, true)
        maps.n[prefix] = { desc = icon .. "Run" }
        maps.n[prefix .. "r"] = { "<Cmd>RunCode<CR>", desc = icon .. "Run (by filetype)" }
        maps.n[prefix .. "f"] = { "<Cmd>RunFile<CR>", desc = icon .. "Run current file" }
        maps.n[prefix .. "p"] = { "<Cmd>RunProject<CR>", desc = icon .. "Run project" }
        maps.n[prefix .. "c"] = { "<Cmd>RunClose<CR>", desc = "Close runner" }
        maps.n[prefix .. "t"] = { "<Cmd>CRFiletype<CR>", desc = "Edit filetype runner" }
      end,
    },
  },
  cmd = { "RunCode", "RunFile", "RunProject", "RunClose", "CRFiletype" },
  -- keymaps are defined via AstroNvim's maps (see astrocore dependency above)
  opts = function()
    return {
      mode = "term", -- run in a terminal
      focus = true, -- focus on runner window
      startinsert = true, -- start in insert mode
      term = {
        position = "vsplit", -- can be "float", "tab", "belowright", "botright", "vsplit"
        size = 60, -- width of vsplit or height of split
      },

      -- mode = "float",
      -- float = {
      --   border = "rounded",
      --   close_key = "q",
      --   height = 0.9,
      --   width = 0.9,
      --   x = 0.5,
      --   y = 0.5,
      -- },
      -- Load filetype and project config from JSON files
      filetype_path = vim.fn.expand "~/.config/nvim/code_runner.json",
      project_path = vim.fn.expand "~/.config/nvim/project_manager.json",
    }
  end,
  config = function(_, opts)
    -- Setup Code Runner
    require("code_runner").setup(opts)

    -- Override run commands to save all buffers before executing
    local create_cmd = vim.api.nvim_create_user_command
    local run_safe = function(fn)
      return function()
        pcall(vim.cmd, "silent! wall")
        local ok, cr = pcall(require, "code_runner")
        if ok and cr and type(cr[fn]) == "function" then cr[fn]() end
      end
    end

    create_cmd("RunCode", run_safe "run_filetype", { force = true, desc = "Save all and run by filetype" })
    create_cmd("RunFile", run_safe "run_file", { force = true, desc = "Save all and run current file" })
    create_cmd("RunProject", run_safe "run_project", { force = true, desc = "Save all and run project" })
  end,
}
