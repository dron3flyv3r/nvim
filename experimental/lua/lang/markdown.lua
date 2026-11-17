local function render() return require "render-markdown" end

---@type lang.Module
return {
  ft = { "markdown" },

  plugins = {
    {
      "MeanderingProgrammer/render-markdown.nvim",
      ft = "markdown",
      dependencies = { "nvim-tree/nvim-web-devicons" },
      opts = {
        enabled = false,
        -- Its default disables the fence-hiding patterns of the markdown query for every buffer, even with
        -- rendering off, and every LSP hover then showed its ```csharp fences.
        patterns = { markdown = { disable = false } },
        anti_conceal = { enabled = false },
        win_options = { concealcursor = { rendered = "nc" } },
      },
      config = function(_, opts)
        render().setup(opts)
        Snacks.toggle.new {
          id = "render_markdown",
          name = "Rendered markdown",
          get = function() return render().get() end,
          set = function(state) render().set(state) end,
        }
      end,
    },
    { "folke/snacks.nvim", opts = { zen = { toggles = { render_markdown = true } } } },
  },

  actions = {
    name = "Markdown",
    priority = 40,

    detect = function(ctx) return ctx.filetype == "markdown" end,

    actions = function()
      local rendered = package.loaded["render-markdown"] and render().get()
      return {
        {
          id = "render",
          label = rendered and "Show the raw markdown" or "Render the markdown",
          category = "Inspect",
          repeatable = false,
          run = function() render().set(not render().get()) end,
        },
      }
    end,
  },
}
