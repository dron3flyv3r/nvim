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
  -- A function rather than a table because `sources.default` is a list, and a
  -- list in an `opts` table replaces rather than appends -- writing it plainly
  -- would drop `lsp`, `path`, `snippets` and `buffer` and leave completion with
  -- nothing but the C++ source below.
  ---@param opts blink.cmp.Config
  opts = function(_, opts)
    -- Tab is indentation, full stop. AstroNvim's default puts completion
    -- selection and snippet jumps ahead of its fallback, so an auto-opened
    -- completion menu can replace text when you meant to indent. Completion
    -- navigation remains on <C-n>/<C-p>; snippets use the explicit
    -- <C-l>/<C-h> mappings in `polish.lua`.
    opts.keymap = opts.keymap or {}
    opts.keymap["<Tab>"] = { "fallback" }
    opts.keymap["<S-Tab>"] = { "fallback" }
    -- Suggestions are navigated deliberately with <C-n>/<C-p>. The cursor
    -- arrows must keep moving through the buffer even while that menu is open.
    opts.keymap["<Up>"] = { "fallback" }
    opts.keymap["<Down>"] = { "fallback" }

    opts.sources = opts.sources or {}
    opts.sources.providers = opts.sources.providers or {}
    opts.sources.providers.lsp = vim.tbl_deep_extend(
      "force",
      opts.sources.providers.lsp or {},
      { transform_items = dedupe_python_lsp }
    )

    -- Out-of-line definitions from the paired header. See
    -- `user/cpp_definition_source.lua` -- the short version is that clangd
    -- completes `Application::ini` to the bare name `init` with no return type
    -- and no parameters, and this fills in the rest.
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
