-- Letting rust-analyzer report the things cargo cannot, without letting it
-- report the things cargo already did.
--
-- THE PROBLEM THIS SPLITS. `rust-lsp.lua` hands diagnostics to bacon-ls, which
-- runs clippy and publishes what the compiler actually said. rust-analyzer can
-- report the same mistakes from its own in-memory analysis, and for a long time
-- the fix was to switch that off entirely (`diagnostics.enable = false`) --
-- one tool per job, no line carrying the same error twice.
--
-- That is right for almost everything and wrong for one case, and the one case
-- is bad enough to be worth this file. A `.rs` file that no `mod` declaration
-- reaches is not part of any crate. cargo never compiles it, so clippy has
-- nothing to say about it, so bacon-ls publishes nothing about it -- and with
-- rust-analyzer silenced too, the file sits there with no diagnostics, no
-- completion, no hover and no inlay hints, and nothing anywhere says why.
-- Measured on a four-file crate: `src/ui/app.rs` with `src/main.rs` missing its
-- `mod ui;` returned 0 diagnostics, 0 inlay hints and an empty hover, while
-- `src/main.rs` in the same crate returned 16 hints and full type information.
-- It looks exactly like a broken editor.
--
-- rust-analyzer knows. It emits `unlinked-file` -- "This file is not included
-- in any crates, so rust-analyzer can't offer IDE services" -- with a quick fix
-- that writes the missing `mod`. It was just being thrown away.
--
-- THE SPLIT, AND WHY IT IS BY CODE SHAPE RATHER THAN BY A LIST. rust-analyzer
-- labels a diagnostic one of two ways:
--
--   * with rustc's own error code, `E0308`, `E0599`, when it is reporting a
--     mistake rustc would also report. Measured: rust-analyzer's copy of the
--     type mismatch on `let x: i32 = "not an int"` arrives as `E0308`, next to
--     bacon-ls's copy of the same error on the same line.
--
--   * with a name of its own, `unlinked-file`, `inactive-code`,
--     `unresolved-proc-macro`, when it is reporting something about the file's
--     relationship to the project rather than about the code -- which is
--     precisely the class cargo structurally cannot reach.
--
-- So the rule is the shape, not an enumeration: drop `E<digits>`, keep the
-- rest. That needs no maintenance as rust-analyzer's diagnostic set grows, and
-- it cannot silently start hiding a new rustc-code diagnostic that bacon-ls was
-- not already reporting -- if rustc has a code for it, cargo emits it.
--
-- `rust-analyzer.diagnostics.disabled` looked like the obvious place for this
-- and is not: it is matched against rust-analyzer's internal names, and a list
-- containing `type-mismatch`, `unresolved-method-call` and seven more was
-- verified to reach the server (read back off `client.settings`) and change
-- nothing -- the diagnostic still arrived, still as `E0308`. Filtering on
-- arrival is done at the client instead, before the entries reach
-- `vim.diagnostic`, so the pickers, the quickfix keys and the sign column all
-- see the same set.
--
-- WHICH HANDLER TO WRAP, AND WHY IT IS BOTH. rust-analyzer advertises
-- `diagnosticProvider`, so Neovim 0.11+ *pulls*: it sends
-- `textDocument/diagnostic` and rust-analyzer answers with a report.
-- `textDocument/publishDiagnostics` is never used by it -- a filter installed
-- only there is on the client, visibly, and simply never runs. (Verified the
-- slow way: the handler was on `client.handlers`, the `E0308` still arrived,
-- and a write-to-file inside the handler produced no file.) bacon-ls has no
-- `diagnosticProvider` and pushes, so both methods are wrapped here -- the
-- push one costs nothing and keeps this correct if rust-analyzer ever stops
-- advertising the capability, or if the filter is pointed at another server.

local M = {}

--- rust-analyzer codes of its own that cargo nonetheless reports too, so the
--- shape rules below cannot see them.
---
--- `syntax-error` is the whole list, and it earns its place: a missing `;`
--- produced four of these next to bacon-ls's two parse errors for the same
--- character. rust-analyzer's arrive from an in-memory parse and are therefore
--- the faster of the two -- but with live diagnostics on, bacon-ls is behind
--- them by a debounce interval, not by a save, and it renders the error the way
--- rustc does. Not worth doubling every half-typed line for.
local ALSO_FROM_CARGO = {
  ["syntax-error"] = true,
}

--- Is this something bacon-ls will report too?
---
--- Three rules, and the middle one is the reason this is not a maintained list.
--- rust-analyzer's codes fall into three naming conventions, and the convention
--- says who owns the diagnostic:
---
---   `E0308`         a rustc ERROR CODE. rustc emits it, so cargo emits it.
---   `non_snake_case`  a rustc or clippy LINT, which is always snake_case.
---                     Measured: `Variable \`Terminal\` should have snake_case
---                     name` arrives from rust-analyzer under exactly the lint
---                     name rustc would use, so it cannot be caught by the
---                     `E` rule and must not need naming individually.
---   `unlinked-file`   rust-analyzer's OWN, which are always kebab-case.
---
--- So: digits after an `E`, or an underscore anywhere, means cargo has it.
--- Hyphens mean rust-analyzer is the only one who will ever say it.
---@param diagnostic lsp.Diagnostic
---@return boolean
function M.duplicates_cargo(diagnostic)
  local code = diagnostic.code
  if type(code) ~= "string" then return false end
  if ALSO_FROM_CARGO[code] then return true end
  return code:match "^E%d+$" ~= nil or code:find("_", 1, true) ~= nil
end

--- Strip the duplicates out of a diagnostics payload, whatever shape it is in.
---
--- Push (`publishDiagnostics`) carries `diagnostics`. Pull
--- (`textDocument/diagnostic`) carries `items`, and may carry reports for other
--- files under `relatedDocuments` -- which is not a corner case for
--- rust-analyzer: it declares `interFileDependencies`, so editing one file
--- routinely returns updated diagnostics for the others in the crate.
---@param report table|nil
local function filter(report)
  if type(report) ~= "table" then return end
  for _, key in ipairs { "diagnostics", "items" } do
    if type(report[key]) == "table" then
      report[key] = vim.tbl_filter(function(d) return not M.duplicates_cargo(d) end, report[key])
    end
  end
  if type(report.relatedDocuments) == "table" then
    for _, related in pairs(report.relatedDocuments) do
      filter(related)
    end
  end
end

--- A diagnostics handler that drops rust-analyzer's copy of anything cargo
--- reports and passes everything else to the handler underneath.
---
--- Wrapping rather than replacing matters: whatever is underneath is what
--- applies `vim.diagnostic.config`, the severity filter in `user.diagnostics`
--- and the underline/sign/virtual-text pipeline. This only edits the payload on
--- the way past.
---
--- `method` picks the fallback so that each wrapper lands on the right default;
--- `inner` is whatever handler was already registered, if any.
---@param method string
---@param inner lsp.Handler|nil
---@return lsp.Handler
function M.handler(method, inner)
  local default = inner or vim.lsp.handlers[method]
  return function(err, result, ctx, config)
    filter(result)
    return default(err, result, ctx, config)
  end
end

--- Install the filter onto an `lsp.ClientConfig`-shaped `handlers` table,
--- wrapping anything already registered for either method.
---@param handlers table<string, lsp.Handler>|nil
---@return table<string, lsp.Handler>
function M.install(handlers)
  handlers = handlers or {}
  for _, method in ipairs { "textDocument/diagnostic", "textDocument/publishDiagnostics" } do
    handlers[method] = M.handler(method, handlers[method])
  end
  return handlers
end

return M
