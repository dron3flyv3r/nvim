-- Completion tweaks for `blink.cmp` (AstroNvim v5's completion engine).
--
-- `signature.enabled` defaults to false upstream, so AstroNvim only styles the
-- window without ever showing it. Turning it on gives the VS Code style hint:
-- a float listing the function's parameters and their types, with the parameter
-- you're currently typing highlighted. It updates as you type commas.
--
-- Note AstroLSP has its own `features.signature_help`; AstroNvim automatically
-- disables that one when blink's is enabled, so there's no double popup.

--- Drop pyrefly's suggestions when basedpyright already made the same one.
---
--- Python runs two servers that can both answer `textDocument/completion` --
--- see `python-lsp.lua` for why -- and blink merges every LSP client's items
--- into one `lsp` source without reconciling them. (Its own config has a
--- `deduplicate` field, but it is marked `TODO: implement`.) Left alone that
--- shows every ordinary completion twice.
---
--- basedpyright is the authority: it resolves types through decorators, which
--- pyrefly cannot. pyrefly exists only to cover the case basedpyright answers
--- with silence -- a half-typed element inside a `[...]` -- and there is
--- nothing of basedpyright's to collide with, so its list passes through whole.
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
  opts = {
    sources = {
      providers = {
        lsp = { transform_items = dedupe_python_lsp },
      },
    },

    signature = {
      enabled = true,
      trigger = {
        enabled = true,
        show_on_insert_on_trigger_character = true, -- pop up as soon as you type `(`
      },
      window = {
        show_documentation = false, -- keep it to the signature line, not the full docstring
      },
    },
  },
}
