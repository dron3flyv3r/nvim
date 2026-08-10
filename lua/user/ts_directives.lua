-- Reinstate the `all = false` contract that Neovim 0.12 dropped.
--
-- THE CRASH THIS FIXES: pressing `K` on anything, or opening any markdown file
-- containing a fenced code block, threw
--
--     Decoration provider "conceal_line" (ns=nvim.treesitter.highlighter):
--     .../vim/treesitter.lua:197: attempt to call method 'range' (a nil value)
--
-- WHY: a treesitter capture can carry a quantifier (`+`, `*`) and therefore
-- match several nodes, so since Neovim 0.11 every query predicate and directive
-- receives `match[capture_id]` as a *list* of nodes. Handlers written before
-- that could opt out by registering with `all = false`, which asked Neovim to
-- keep passing a single node:
--
--     -- nvim-treesitter/lua/nvim-treesitter/query_predicates.lua:19
--     local opts = vim.fn.has "nvim-0.10" == 1 and { force = true, all = false } or true
--
-- Neovim 0.12's `add_directive`/`add_predicate` read only `force` and ignore
-- `all` completely, so those handlers now get a list where they expect a node,
-- and `get_node_text` calls `:range()` on a plain Lua table.
--
-- Six handlers in that file are affected -- `nth?`, `is?`, `kind-eq?`,
-- `set-lang-from-mimetype!`, `set-lang-from-info-string!` and `downcase!` --
-- but the one you hit constantly is `set-lang-from-info-string!`, which
-- `queries/markdown/injections.scm` runs on every fenced code block. An LSP
-- hover popup is markdown with a fenced code block, hence `K`.
--
-- WHY PATCH RATHER THAN UPDATE: nvim-treesitter's `master` branch is archived.
-- The commit this config pins is literally the one announcing it
-- ("docs(readme)!: announce archiving of master branch", 2025-05-24), so no
-- upstream fix is coming. The supported branch for Neovim 0.11+ is `main`, but
-- AstroNvim's treesitter spec is built on `master`'s module system
-- (`main = "nvim-treesitter.configs"`, plus `highlight`/`indent`/`textobjects`
-- module options), so moving branches is a migration, not a one-line change.
--
-- This wraps the two registration functions instead of rewriting the six
-- handlers, so it needs no copy of nvim-treesitter's language-alias tables and
-- covers any other handler that opts into the old contract. It is a no-op for
-- handlers that do not pass `all = false`, which means it costs nothing on a
-- Neovim old enough to still honour it and disappears by itself if the plugin
-- is ever updated to the modern API.
--
-- Called from `lua/lazy_setup.lua`, which is the last moment before plugin
-- `init` functions run -- AstroNvim's treesitter spec requires
-- `nvim-treesitter.query_predicates` from its `init` to get the custom queries
-- onto the runtimepath early, so patching any later would miss the
-- registrations entirely.
local M = {}

local applied = false

---Collapse Neovim 0.11+'s per-capture node lists back to single nodes.
---
---Already-single nodes are userdata rather than tables, so they fall through
---untouched and this stays correct on a Neovim that still honours `all`.
---@param match table<integer, TSNode|TSNode[]>
---@return table<integer, TSNode>
local function unwrap(match)
  local single = {}
  for id, captured in pairs(match) do
    single[id] = type(captured) == "table" and captured[1] or captured
  end
  return single
end

--- Wrap `vim.treesitter.query.add_directive` / `add_predicate` so handlers
--- registered with `all = false` keep getting what they asked for.
function M.setup()
  if applied then return end
  applied = true

  local query = require "vim.treesitter.query"
  for _, register in ipairs { "add_directive", "add_predicate" } do
    local original = query[register]
    query[register] = function(name, handler, opts)
      if type(opts) == "table" and opts.all == false then
        local legacy = handler
        -- Only `match` changes shape; `pattern`, `source`, the predicate and
        -- the metadata table are passed straight through, so directives still
        -- write their results where the caller reads them.
        handler = function(match, ...) return legacy(unwrap(match), ...) end
      end
      return original(name, handler, opts)
    end
  end
end

return M
