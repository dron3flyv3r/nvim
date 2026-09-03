---@param items blink.cmp.CompletionItem[]
---@return blink.cmp.CompletionItem[]
local function dedupe_python_lsp(_, items)
  local names = {} ---@type table<integer, string>
  local function client_name(id)
    if not id then return "" end
    local cached = names[id]
    if cached == nil then
      local client = vim.lsp.get_client_by_id(id)
      cached = client and client.name or ""
      names[id] = cached
    end
    return cached
  end

  local seen, has_pyrefly = {}, false
  for _, item in ipairs(items) do
    local name = client_name(item.client_id)
    if name == "pyrefly" then
      has_pyrefly = true
    elseif name == "basedpyright" then
      seen[item.label] = true
    end
  end
  -- Not a Python buffer, or only one of the two answered: nothing to reconcile,
  -- and this runs on every keystroke, so leave without touching the list.
  if not has_pyrefly or not next(seen) then return items end

  local kept = {}
  for _, item in ipairs(items) do
    if client_name(item.client_id) ~= "pyrefly" or not seen[item.label] then table.insert(kept, item) end
  end
  return kept
end

---@type LazySpec
return {
  "Saghen/blink.cmp",
  ---@param opts blink.cmp.Config
  opts = function(_, opts)
    opts.keymap = opts.keymap or {}
    opts.keymap["<Up>"] = { "fallback" }
    opts.keymap["<Down>"] = { "fallback" }

    opts.sources = opts.sources or {}
    opts.sources.providers = opts.sources.providers or {}
    opts.sources.providers.lsp =
      vim.tbl_deep_extend("force", opts.sources.providers.lsp or {}, { transform_items = dedupe_python_lsp })

    opts.sources.providers.cpp_definition = {
      name = "C++ def",
      module = "user.languages.cpp.definition_source",
      -- Above `lsp` (the default is 0), so when both answer -- and they both
      -- will, since clangd offers the bare name for the same prefix -- the
      -- complete definition is the item under the cursor.
      score_offset = 10,
    }
    opts.sources.default = require("astrocore").list_insert_unique(
      opts.sources.default or { "lsp", "path", "snippets", "buffer" },
      { "cpp_definition" }
    )

    opts.signature = vim.tbl_deep_extend("force", opts.signature or {}, {
      enabled = true,
      trigger = {
        enabled = true,
        show_on_insert_on_trigger_character = true, -- pop up as soon as you type `(`
      },
      window = {
        show_documentation = false, -- keep it to the signature line, not the full docstring
      },
    })

    return opts
  end,
}
