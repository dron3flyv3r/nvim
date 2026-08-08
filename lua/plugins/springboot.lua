return {
  "elmcgill/springboot-nvim",
  dependencies = {
    "neovim/nvim-lspconfig",
    "mfussenegger/nvim-jdtls",
    { "AstroNvim/astroui", opts = { icons = { SpringBoot = "󰜈" } } },
    {
      "AstroNvim/astrocore",
      opts = function(_, opts)
        local maps = opts.mappings
        local prefix = "<leader>J"
        local icon = require("astroui").get_icon("SpringBoot", 1, true)
        local function spring_action(fn)
          return function()
            local ok, spring = pcall(require, "springboot-nvim")
            if ok and spring and type(spring[fn]) == "function" then spring[fn]() end
          end
        end

        maps.n[prefix] = { desc = icon .. "Spring Boot" }
        maps.n[prefix .. "r"] = { spring_action "boot_run", desc = icon .. "Run Project" }
        maps.n[prefix .. "c"] = { spring_action "generate_class", desc = icon .. "Create Class" }
        maps.n[prefix .. "i"] = { spring_action "generate_interface", desc = icon .. "Create Interface" }
        maps.n[prefix .. "e"] = { spring_action "generate_enum", desc = icon .. "Create Enum" }
      end,
    },
  },
  config = function()
    require("springboot-nvim").setup {}
  end,
}
