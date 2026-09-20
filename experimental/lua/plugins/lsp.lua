local group = vim.api.nvim_create_augroup("plugins_lsp_keys", { clear = true })

---@param source string
local function pick(source)
  return function() require("snacks").picker[source]() end
end

local keys = {
  { "grd", "lsp_definitions", "Go to definition" },
  { "gd", "lsp_definitions", "Go to definition" },
  { "grr", "lsp_references", "List references" },
  { "gri", "lsp_implementations", "List implementations" },
  { "grt", "lsp_type_definitions", "Go to type definition" },
}

vim.api.nvim_create_autocmd("LspAttach", {
  group = group,
  callback = function(args)
    for _, key in ipairs(keys) do
      local lhs, source, desc = key[1], key[2], key[3]
      vim.keymap.set("n", lhs, pick(source), { buffer = args.buf, desc = desc, nowait = true })
    end
  end,
})

-- Only a marker so the dependency is visible to lazy and to the next reader.
-- It must not carry `init`/`config`: lazy replaces rather than merges function
-- fields, so a second one here would silently drop the spec in snacks.lua.
---@type LazySpec
return { "folke/snacks.nvim", optional = true }
