local function check(ok, message)
  if not ok then error("config smoke check: " .. message, 0) end
end

for _, module in ipairs {
  "user.autosave",
  "user.context",
  "user.diagnostics",
  "user.integrations.notebook",
  "user.integrations.notebook.cells",
  "user.integrations.unity",
  "user.integrations.unity.actions",
  "user.inlay_hints.handler",
  "user.inlay_hints.matcher",
  "user.inlay_hints.store",
  "user.inlay_hints.syntax",
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
  "TeamtypeHost",
  "TeamtypeJoin",
} do
  check(commands[name] ~= nil, "missing :" .. name)
end

for _, lhs in ipairs {
  "<Leader>ra",
  "<Leader>Up",
  "<Leader>Us",
  "<Leader>Ur",
  "<Leader>Ut",
  "<Leader>Ua",
  "<Leader>ae",
  "<Leader>aE",
  "<Leader>aa",
} do
  check(vim.fn.maparg(lhs, "n") ~= "", "missing normal-mode mapping " .. lhs)
end

local rust_spec = table.concat(vim.fn.readfile "lua/plugins/rust-run.lua", "\n")
for _, lhs in ipairs { "<Leader>Rr", "<Leader>Rt", "<Leader>Rd", "<Leader>Rb", "<Leader>Re", "<Leader>Ro" } do
  check(rust_spec:find(lhs, 1, true) ~= nil, "missing Rust LSP mapping declaration " .. lhs)
end

local lazy = require "lazy.core.config"
check(lazy.plugins["codex.nvim"] == nil, "codex.nvim should not be registered")

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

dofile "tests/notebook_cells_spec.lua"
dofile "tests/inlay_hints_spec.lua"
print "CONFIG_SMOKE_OK"
