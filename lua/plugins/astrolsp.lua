-- AstroLSP: how language servers attach, format, and what they show.
-- Configuration documentation: `:h astrolsp`
--
-- Per-language tuning lives next door -- see `python-lsp.lua`. This file is the
-- behaviour that should be true of every server.
-- ── LSP navigation goes through the picker ────────────────────────────────────
--
-- Every "where is this used / defined / implemented" key in AstroNvim ends in
-- the QUICKFIX LIST: `vim.lsp.buf.references()` and friends hand their results
-- to `vim.fn.setqflist`, which draws a flat strip at the bottom of the screen
-- with no filtering, no fuzzy matching and no preview. The LSP data is fine --
-- roslyn knows perfectly well who calls a method -- it is the window that makes
-- it feel worse than a grep.
--
-- snacks.picker has an LSP source for each of these, and it is the same picker
-- as `<Leader>ff` and `<Leader>fw`: list on the left, live preview of the hit
-- on the right, fuzzy-filter as you type. Which also means the keys you already
-- know work inside it -- `<C-v>` / `<C-s>` to open in a split, `<C-q>` to send
-- the list (as filtered, not as found) to the quickfix list for when you really
-- do want to walk it with `]q`, and `<Leader>f<CR>` to reopen the last one.

--- Wrap one of snacks' LSP pickers as a mapping.
---
--- `hint` marks the keys that answer "find EVERY x" rather than "take me to
--- the one x". Those are the keys a half-loaded language server actively
--- misleads: an incomplete reference list is indistinguishable from a complete
--- one, and on a solution the size of a Unity project roslyn takes a while.
--- `gd` deliberately does not hint -- a notification on every jump to a
--- definition is worse than no notification at all.
---@param source string A `Snacks.picker` source name.
---@param opts? table Passed to the picker, plus our own `hint`.
---@return fun()
local function pick(source, opts)
  opts = vim.deepcopy(opts or {})
  local hint = opts.hint
  opts.hint = nil
  return function()
    -- `vim.lsp.status()` is the same progress text the statusline shows, and is
    -- the empty string when every server is idle.
    if hint then
      local progress = vim.lsp.status()
      if progress ~= "" then
        vim.notify(
          "A language server is still working, so this list may be incomplete:\n" .. progress,
          vim.log.levels.INFO,
          { title = "LSP" }
        )
      end
    end
    require("snacks").picker[source](opts)
  end
end

---@type LazySpec
return {
  "AstroNvim/astrolsp",
  ---@type AstroLSPOpts
  opts = {
    features = {
      codelens = true,

      -- Inlay hints: the greyed-in `param:` labels and inferred types that VS
      -- Code shows between your own tokens. basedpyright and clangd both
      -- provide them. `<Leader>uH` toggles them off when a line gets busy.
      inlay_hints = true,

      semantic_tokens = true,
    },

    -- Format on save, for every filetype that has a formatter attached:
    -- ruff for Python, clangd (clang-format) for C/C++, stylua for Lua.
    formatting = {
      format_on_save = {
        enabled = true,
        allow_filetypes = {}, -- empty = all filetypes
        ignore_filetypes = {},
      },
      -- Servers that may NOT format, because none-ls already runs the same tool
      -- and two formatters on one buffer is how you get a fight on every save.
      disabled = {
        -- stylua, via none-ls, and it reads `.stylua.toml`.
        "lua_ls",
        -- clang-format, via none-ls. clangd embeds clang-format and would
        -- happily do it too -- same tool, same `.clang-format` file, so the
        -- result is identical and the second pass is pure waste.
        "clangd",
      },
      timeout_ms = 1000,
    },

    -- Servers installed outside Mason that should still be set up.
    servers = {},

    ---@diagnostic disable: missing-fields
    config = {},

    handlers = {},

    -- NOTE: the AstroNvim template ships an `lsp_codelens_refresh` autocmd here
    -- that re-runs codelens on InsertLeave/BufEnter. It is gone on purpose:
    -- `features.codelens` above already refreshes on attach, and on Neovim 0.12
    -- codelens is managed by the `vim.lsp._capability` framework, which handles
    -- its own refreshing. The autocmd was both redundant and a second call site
    -- for `vim.lsp.codelens.refresh()`, which is deprecated in favour of
    -- `vim.lsp.codelens.enable()` and warns on startup.
    autocmds = {},

    mappings = {
      n = {
        -- Neovim gives every attached LSP buffer a plain `K` mapping. Keep
        -- the familiar key, but give documentation enough room to show a Rust
        -- signature and its docs without a narrow, hard-to-read popup. A
        -- second `K` focuses it, where normal scrolling, searching and `q`
        -- work as expected.
        K = {
          function() require("user.hover").open() end,
          desc = "Documentation for current symbol",
          cond = "textDocument/hover",
        },
        -- `cond` is a method name: the key only exists on buffers whose
        -- server can actually answer it, so `<Leader>lk` is absent in a
        -- filetype without call hierarchy rather than silently doing nothing.
        --
        -- Going somewhere: one result jumps straight there (`auto_confirm` is
        -- on by default in these sources), several open the picker. Both push
        -- the tagstack, so `<C-t>` and `<BS>` come back.
        gd = {
          pick "lsp_definitions",
          desc = "Definition of current symbol",
          cond = "textDocument/definition",
        },
        gD = {
          pick "lsp_declarations",
          desc = "Declaration of current symbol",
          cond = "textDocument/declaration",
        },
        gy = {
          pick "lsp_type_definitions",
          desc = "Definition of current type",
          cond = "textDocument/typeDefinition",
        },
        gO = {
          pick "lsp_symbols",
          desc = "Symbols in this file",
          cond = "textDocument/documentSymbol",
        },

        -- Finding everything: `auto_confirm = false` because you pressed this
        -- to SEE the list. Left on, a symbol with exactly one reference would
        -- teleport you to it and never show you that it was the only one --
        -- which is usually the most interesting thing the answer contains.
        ["<Leader>lR"] = {
          pick("lsp_references", { auto_confirm = false, hint = true }),
          desc = "References of current symbol",
          cond = "textDocument/references",
        },
        grr = {
          pick("lsp_references", { auto_confirm = false, hint = true }),
          desc = "References of current symbol",
          cond = "textDocument/references",
        },
        -- Implementations, for an `interface` or an `abstract` method: every
        -- type that implements it. `gri` is Neovim's own key for this and is
        -- overridden here per-buffer; `<Leader>li` is the same thing from the
        -- `<Leader>l` menu.
        gri = {
          pick("lsp_implementations", { hint = true }),
          desc = "Implementations of current symbol",
          cond = "textDocument/implementation",
        },
        ["<Leader>li"] = {
          pick("lsp_implementations", { hint = true }),
          desc = "Implementations of current symbol",
          cond = "textDocument/implementation",
        },

        -- Call hierarchy, on `j` and `k` because the mnemonic is the direction
        -- you move through the call tree: `k` goes UP to the callers, `j` goes
        -- DOWN into the callees. This is the pair a grep answers badly and a
        -- language server answers exactly -- `Move()` finds every text match
        -- for the word, `<Leader>lk` finds the code that actually calls THIS
        -- `Move`.
        ["<Leader>lk"] = {
          pick("lsp_incoming_calls", { hint = true }),
          desc = "Incoming calls (who calls this)",
          cond = "textDocument/prepareCallHierarchy",
        },
        ["<Leader>lj"] = {
          pick("lsp_outgoing_calls", { hint = true }),
          desc = "Outgoing calls (what this calls)",
          cond = "textDocument/prepareCallHierarchy",
        },

        -- Workspace symbols. The default prompts for a string through
        -- `vim.ui.input` FIRST and only then queries -- so a typo costs you the
        -- whole round trip. The picker queries live as you type instead.
        ["<Leader>lG"] = {
          pick "lsp_workspace_symbols",
          desc = "Search workspace symbols",
          cond = "workspace/symbol",
        },
        -- ── The global autoformat toggle, repaired ───────────────────────
        --
        -- `<Leader>uf` turns format-on-save off for THIS buffer and always
        -- worked. `<Leader>uF` is the global one and, as AstroNvim ships it,
        -- silently does nothing in the buffers you would press it in.
        --
        -- MEASURED, in a Python buffer with ruff attached:
        --
        --     vim.b.autoformat after attach: true
        --     after <Leader>uF -> enabled=false  vim.b.autoformat=true
        --
        -- AstroLSP's `on_attach` writes `vim.b.autoformat` eagerly on every
        -- buffer whose server can format, and the write-time check reads that
        -- FIRST, falling back to the global only when it is nil
        -- (`_astrolsp_autocmds.lua`). So flipping the global leaves every
        -- already-open buffer with its own stale `true` -- the notification
        -- says "Global autoformatting off" and the next save formats anyway.
        --
        -- Clearing the per-buffer values is what makes the global one global
        -- again: with them nil, every buffer falls through to the flag that
        -- was just toggled, and buffers that attach later read it in
        -- `on_attach`. The cost is that a single buffer you had toggled by
        -- hand rejoins the group, which is what "global" should mean.
        ["<Leader>uF"] = {
          function()
            require("astrolsp.toggles").autoformat()
            for _, buf in ipairs(vim.api.nvim_list_bufs()) do
              if vim.api.nvim_buf_is_valid(buf) then vim.b[buf].autoformat = nil end
            end
          end,
          desc = "Toggle autoformatting (global)",
        },
        ["<Leader>uY"] = {
          function() require("astrolsp.toggles").buffer_semantic_tokens() end,
          desc = "Toggle LSP semantic highlight (buffer)",
          cond = function(client)
            -- `client:supports_method` (method call) -- the dot form is
            -- deprecated as of Neovim 0.11 and warns on every attach.
            return client:supports_method "textDocument/semanticTokens/full" and vim.lsp.semantic_tokens ~= nil
          end,
        },
      },
    },
  },
}
