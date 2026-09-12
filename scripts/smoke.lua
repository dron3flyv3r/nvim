local function check(ok, message)
  if not ok then error("config smoke check: " .. message, 0) end
end

for _, module in ipairs {
  "user.autosave",
  "user.context",
  "user.diagnostics",
  "user.diff_hud",
  "user.diff_keys",
  "user.diff_review",
  "user.integrations.notebook",
  "user.integrations.notebook.cells",
  "user.integrations.unity",
  "user.integrations.unity.actions",
  "user.inlay_hints.handler",
  "user.inlay_hints.matcher",
  "user.inlay_hints.store",
  "user.inlay_hints.syntax",
  "user.languages.rust.project",
  "user.teamtype.panel",
  "user.teamtype.peers",
  "user.workbench.tasks",
} do
  local ok, err = pcall(require, module)
  check(ok, ("cannot load %s: %s"):format(module, err))
end

local commands = vim.api.nvim_get_commands { builtin = false }
for _, name in ipairs {
  "AutosaveStatus",
  "ContextActions",
  "ContextStatus",
  "NotebookBootstrap",
  "NotebookHealth",
  "RustDependencyFeatures",
  "RustDependencySearch",
  "RustProjectRefresh",
  "TeamtypeHost",
  "TeamtypeJoin",
  "TeamtypeMirror",
  "TeamtypeMirrorHere",
  "TeamtypePeers",
} do
  check(commands[name] ~= nil, "missing :" .. name)
end

for _, lhs in ipairs {
  "<Leader>r",
  "<Leader>R",
  "<Leader>ae",
  "<Leader>aE",
  "<Leader>aa",
} do
  check(vim.fn.maparg(lhs, "n") ~= "", "missing normal-mode mapping " .. lhs)
end

local rust_spec = table.concat(vim.fn.readfile "lua/plugins/rust-run.lua", "\n")
check(not rust_spec:find("<Leader>R", 1, true), "Rust actions should use native keys or the contextual picker")
local quickfix_spec = table.concat(vim.fn.readfile "lua/plugins/quickfix.lua", "\n")
check(quickfix_spec:find('maps.n["gra"]', 1, true) ~= nil, "native gra must include the smart quick-fix wrapper")

local lazy = require "lazy.core.config"
check(lazy.plugins["codex.nvim"] == nil, "codex.nvim should not be registered")

-- The review's key strip is written by hand, so it can only stay honest if the
-- keys it advertises are the keys the Diffview spec actually binds.
local git_spec = table.concat(vim.fn.readfile "lua/plugins/git.lua", "\n")
local keys_spec = table.concat(vim.fn.readfile "lua/user/diff_keys.lua", "\n")
for _, key in ipairs { "H", "L", "B", "X" } do
  check(git_spec:find(('"n", "%s", take_side'):format(key), 1, true) ~= nil, "merge key " .. key .. " is not bound")
  check(
    keys_spec:find(('keys = "%s"'):format(key), 1, true) ~= nil,
    "merge key " .. key .. " is missing from the strip"
  )
end
-- The line-level take and the walk back over resolutions are the two keys the
-- strip cannot be wrong about: one edits the file, the other claims a decision.
check(git_spec:find('"n", "<CR>", take_lines(false)', 1, true) ~= nil, "taking one line is not bound")
check(git_spec:find('"x", "<CR>", take_lines(true)', 1, true) ~= nil, "taking selected lines is not bound")
check(keys_spec:find('keys = "<CR>"', 1, true) ~= nil, "taking lines is missing from the strip")
check(git_spec:find('"n", "]r", nav_resolution', 1, true) ~= nil, "walking resolutions is not bound")
check(keys_spec:find('keys = "]r/[r"', 1, true) ~= nil, "walking resolutions is missing from the strip")

-- Leaving the review has to go through the transaction, so the bound key must
-- be the wrapper and never Diffview's own goto_file action.
check(git_spec:find('"n", "gf", leave "edit"', 1, true) ~= nil, "leaving the review at a file is not bound")
check(keys_spec:find('keys = "gf"', 1, true) ~= nil, "leaving the review is missing from the strip")
check(not git_spec:find("actions.goto_file", 1, true), "goto_file must not be bound directly")

for _, key in ipairs { "gH", "gL", "gB" } do
  check(
    git_spec:find(('"n", "%s", take_side'):format(key), 1, true) ~= nil,
    "whole-file key " .. key .. " is not bound"
  )
end

-- Catch accidental duplicate declarations in this repository. Runtime maps
-- cannot reveal that one declaration silently replaced another, so inspect the
-- literal AstroCore declarations before they are merged.
local seen, duplicates = {}, {}
for _, file in ipairs(vim.fn.glob(vim.fn.getcwd() .. "/lua/**/*.lua", false, true)) do
  for line in io.lines(file) do
    local mode, lhs = line:match 'maps%.([nivxsotc]+)%["([^"]+)"%]%s*='
    if mode and lhs then
      local id = mode .. " " .. lhs
      if seen[id] then duplicates[#duplicates + 1] = ("%s (%s, %s)"):format(id, seen[id], file) end
      seen[id] = file
    end
  end
end
check(#duplicates == 0, "duplicate local mappings:\n" .. table.concat(duplicates, "\n"))

dofile "tests/git_navigation_spec.lua"
dofile "tests/notebook_cells_spec.lua"
dofile "tests/inlay_hints_spec.lua"
dofile "tests/rust_dependencies_spec.lua"
dofile "tests/diff_goto_spec.lua"
dofile "tests/teamtype_peers_spec.lua"
print "CONFIG_SMOKE_OK"
