---@param ctx snacks.picker.preview.ctx
local function code_action_preview(ctx)
  local item, picker = ctx.item, ctx.picker
  local preview = require("core.code_action").preview(item.item, function()
    if not picker.closed and picker:current { resolve = false } == item then
      picker.preview:show(picker, { force = true })
    end
  end)

  ctx.preview:set_title(item.item.action.title)
  if not preview then
    ctx.preview:reset()
    ctx.preview:set_lines { "Asking the server for the change…" }
  elseif preview.diff then
    item.diff = preview.diff
    Snacks.picker.preview.diff(ctx)
    if #preview.notes > 0 then ctx.preview:set_title(table.concat(preview.notes, " · ")) end
  else
    ctx.preview:reset()
    ctx.preview:set_lines(preview.notes)
  end
end

---@type LazySpec
return {
  "folke/snacks.nvim",
  priority = 1000,
  lazy = false,
  ---@type snacks.Config
  opts = {
    bigfile = { enabled = true },
    dashboard = { enabled = true },
    explorer = { enabled = true },
    -- vim.ui.img is a set/get/del backend for raw PNG bytes, not in-buffer
    -- rendering. snacks does the detection, conversion and placement.
    image = { enabled = true },
    indent = { enabled = true },
    input = { enabled = true },
    notifier = { enabled = true, timeout = 3000 },
    -- These lists are short and rarely need filtering, so focus the list
    -- instead of the prompt: j/k work without a mode change, `i` or `/`
    -- reaches the filter when it is actually wanted. Pickers that exist to be
    -- typed into, like files and grep, keep the default prompt focus.
    picker = {
      enabled = true,
      sources = {
        select = {
          focus = "list",
          -- `<Leader>r` asks for this kind. Its menu is long, its labels are
          -- sentences, and switching between Run and Debug is a search rather
          -- than a scroll -- so the prompt is focused and the two keys that
          -- would otherwise toggle a multi-selection move the cursor instead.
          kinds = {
            action = {
              focus = "input",
              win = {
                input = {
                  keys = {
                    ["<Tab>"] = { "list_down", mode = { "i", "n" } },
                    ["<S-Tab>"] = { "list_up", mode = { "i", "n" } },
                    -- snacks' default cancels in normal mode only, so starting
                    -- in the prompt would otherwise cost two presses to dismiss.
                    ["<Esc>"] = { "cancel", mode = { "i", "n" } },
                  },
                },
              },
            },
            codeaction = {
              -- A whole layout rather than a tweak of the `select` preset, which
              -- hides the preview and whose list children merge by position.
              layout = {
                layout = {
                  backdrop = false,
                  width = 0.6,
                  min_width = 80,
                  max_width = 120,
                  height = 0.8,
                  box = "vertical",
                  border = true,
                  title = "{title}",
                  title_pos = "center",
                  { win = "input", height = 1, border = "bottom" },
                  { win = "list", border = "none" },
                  { win = "preview", title = "{preview}", border = "top" },
                },
              },
              preview = code_action_preview,
            },
          },
        },
        lsp_references = { focus = "list" },
        lsp_definitions = { focus = "list" },
        lsp_implementations = { focus = "list" },
        lsp_type_definitions = { focus = "list" },
      },
    },
    quickfile = { enabled = true },
    scroll = { enabled = true },
    scope = { enabled = true },
    statuscolumn = { enabled = true },
    words = { enabled = true },
  },
  keys = {
    { "<Leader><Space>", function() Snacks.picker.smart() end, desc = "Smart find files" },
    { "<Leader>,", function() Snacks.picker.buffers() end, desc = "Buffers" },
    { "<Leader>/", function() Snacks.picker.grep() end, desc = "Grep" },
    { "<Leader>:", function() Snacks.picker.command_history() end, desc = "Command history" },
    { "<Leader>e", function() Snacks.explorer() end, desc = "File explorer" },
    { "<Leader>.", function() Snacks.scratch() end, desc = "Toggle scratch buffer" },
    { "<Leader>z", function() Snacks.zen() end, desc = "Toggle zen mode" },

    { "<Leader>fb", function() Snacks.picker.buffers() end, desc = "Buffers" },
    { "<Leader>fc", function() Snacks.picker.files { cwd = vim.fn.stdpath "config" } end, desc = "Find config file" },
    { "<Leader>ff", function() Snacks.picker.files() end, desc = "Find files" },
    { "<Leader>fp", function() Snacks.picker.projects() end, desc = "Projects" },
    { "<Leader>fr", function() Snacks.picker.recent() end, desc = "Recent" },

    { "<Leader>sb", function() Snacks.picker.lines() end, desc = "Buffer lines" },
    { "<Leader>sB", function() Snacks.picker.grep_buffers() end, desc = "Grep open buffers" },
    { "<Leader>sg", function() Snacks.picker.grep() end, desc = "Grep" },
    { "<Leader>sw", function() Snacks.picker.grep_word() end, desc = "Selection or word", mode = { "n", "x" } },
    { '<Leader>s"', function() Snacks.picker.registers() end, desc = "Registers" },
    { "<Leader>sa", function() Snacks.picker.autocmds() end, desc = "Autocmds" },
    { "<Leader>sc", function() Snacks.picker.command_history() end, desc = "Command history" },
    { "<Leader>sC", function() Snacks.picker.commands() end, desc = "Commands" },
    { "<Leader>sd", function() Snacks.picker.diagnostics() end, desc = "Diagnostics" },
    { "<Leader>sD", function() Snacks.picker.diagnostics_buffer() end, desc = "Buffer diagnostics" },
    { "<Leader>sh", function() Snacks.picker.help() end, desc = "Help pages" },
    { "<Leader>sH", function() Snacks.picker.highlights() end, desc = "Highlights" },
    { "<Leader>sj", function() Snacks.picker.jumps() end, desc = "Jumps" },
    { "<Leader>sk", function() Snacks.picker.keymaps() end, desc = "Keymaps" },
    { "<Leader>sm", function() Snacks.picker.marks() end, desc = "Marks" },
    { "<Leader>sM", function() Snacks.picker.man() end, desc = "Man pages" },
    { "<Leader>sq", function() Snacks.picker.qflist() end, desc = "Quickfix list" },
    { "<Leader>sr", function() Snacks.picker.resume() end, desc = "Resume" },
    { "<Leader>su", function() Snacks.picker.undo() end, desc = "Undo history" },

    { "<Leader>ss", function() Snacks.picker.lsp_symbols() end, desc = "LSP symbols" },
    { "<Leader>sS", function() Snacks.picker.lsp_workspace_symbols() end, desc = "LSP workspace symbols" },

    { "<Leader>n", function() Snacks.notifier.show_history() end, desc = "Notification history" },
    { "<Leader>un", function() Snacks.notifier.hide() end, desc = "Dismiss notifications" },
    { "<Leader>bd", function() Snacks.bufdelete() end, desc = "Delete buffer" },
    { "<Leader>uC", function() Snacks.picker.colorschemes() end, desc = "Colorschemes" },

    { "]]", function() Snacks.words.jump(vim.v.count1) end, desc = "Next reference", mode = { "n", "t" } },
    { "[[", function() Snacks.words.jump(-vim.v.count1) end, desc = "Prev reference", mode = { "n", "t" } },
  },
  init = function()
    vim.api.nvim_create_autocmd("User", {
      pattern = "VeryLazy",
      callback = function()
        Snacks.toggle.option("spell", { name = "Spelling" }):map "<Leader>us"
        Snacks.toggle.option("wrap", { name = "Wrap" }):map "<Leader>uw"
        Snacks.toggle.option("relativenumber", { name = "Relative Number" }):map "<Leader>uL"
        Snacks.toggle.diagnostics():map "<Leader>ud"
        Snacks.toggle.line_number():map "<Leader>ul"
        Snacks.toggle.treesitter():map "<Leader>uT"
        Snacks.toggle.inlay_hints():map "<Leader>uh"
        Snacks.toggle
          .new({
            id = "codelens",
            name = "Code Lens",
            get = function() return require("core.codelens").is_enabled() end,
            set = function(state) require("core.codelens").set(state) end,
          })
          :map "<Leader>uc"
        Snacks.toggle.indent():map "<Leader>ug"
        Snacks.toggle.dim():map "<Leader>uD"
        Snacks.toggle.scroll():map "<Leader>uS"
      end,
    })
  end,
}
