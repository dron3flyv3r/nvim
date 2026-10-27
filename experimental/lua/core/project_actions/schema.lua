local json = require "core.project_actions.json"

local M = {}

M.FILE = ".nvim/actions.json"
M.CATEGORIES = require("core.actions").CATEGORIES

---@class core.project_actions.Field
---@field name string
---@field kind string|string[]
---@field required? boolean
---@field snippet string
---@field doc string

---@type core.project_actions.Field[]
M.TOP = {
  {
    name = "actions",
    kind = "array",
    required = true,
    snippet = '"actions": [\n\t{\n\t\t$0\n\t}\n]',
    doc = "This project's own `<Leader>r` actions, one object each.",
  },
}

---@type core.project_actions.Field[]
M.ACTION = {
  {
    name = "label",
    kind = "string",
    required = true,
    snippet = '"label": "$1"',
    doc = "What the menu shows. Imperative and sentence case: *Sync to the Mac and build*.",
  },
  {
    name = "category",
    kind = "string",
    required = true,
    snippet = '"category": "$1"',
    doc = "The heading it is listed under, one of " .. table.concat(M.CATEGORIES, ", ") .. ".",
  },
  {
    name = "description",
    kind = "string",
    snippet = '"description": "$1"',
    doc = "Shown beside the label in the menu, and searched with it.",
  },
  {
    name = "cmd",
    kind = { "array", "string" },
    required = true,
    snippet = '"cmd": ["$1"]',
    doc = "The command. A list is argv and runs with no shell; a string is a shell line and runs through `sh -c`.",
  },
  {
    name = "cwd",
    kind = "string",
    snippet = '"cwd": "$1"',
    doc = "Where it runs, relative to the project root. Defaults to the root.",
  },
  {
    name = "env",
    kind = "object",
    snippet = '"env": { "$1": "$2" }',
    doc = "Extra environment variables. Every value is a string.",
  },
  {
    name = "errorformat",
    kind = "string",
    snippet = '"errorformat": "$1"',
    doc = "An `'errorformat'` that parses the output into quickfix on exit. Without one, quickfix is left alone.",
  },
  {
    name = "queue",
    kind = "boolean",
    snippet = '"queue": ${1:false}',
    doc = "Wait for the running task first. Defaults to true; set false for anything that keeps running, "
      .. "so later builds do not wait behind it.",
  },
}

local ARTICLE = { string = "a string", array = "a list", object = "an object", boolean = "true or false" }

---@param kind string|string[]
---@return string
function M.describe(kind)
  local kinds = type(kind) == "table" and kind or { kind }
  return table.concat(vim.tbl_map(function(k) return ARTICLE[k] or k end, kinds), " or ")
end

---@param fields core.project_actions.Field[]
---@param name string
---@return core.project_actions.Field?
function M.field(fields, name)
  for _, field in ipairs(fields) do
    if field.name == name then return field end
  end
end

---@param path string the actions file
---@return string
function M.root(path) return vim.fs.dirname(vim.fs.dirname(path)) end

---@class core.project_actions.Problem
---@field s integer
---@field e integer
---@field line integer 1-based
---@field severity "error"|"warning"|"hint"
---@field message string

---@class core.project_actions.Entry
---@field label string
---@field category? core.ActionCategory
---@field description? string
---@field cmd? string[]
---@field cwd string
---@field env? table<string, string>
---@field errorformat? string
---@field queue boolean
---@field problem? string the first error, which makes the action unavailable

---@class core.project_actions.Config
---@field actions core.project_actions.Entry[]

---@param kind string|string[]
---@param actual string
local function matches(kind, actual)
  if type(kind) == "table" then return vim.list_contains(kind, actual) end
  return kind == actual
end

---@param text string
---@param root string
---@return core.project_actions.Config?
---@return core.project_actions.Problem[]
function M.check(text, root)
  local starts = json.lines(text)
  ---@type core.project_actions.Problem[]
  local problems = {}

  local function report(s, e, severity, message)
    local line = json.position(starts, s).line + 1
    problems[#problems + 1] = { s = s, e = e, line = line, severity = severity, message = message }
  end
  local function at(node, severity, message) report(node.s, node.e, severity, message) end
  local function at_brace(node, severity, message) report(node.s, node.s + 1, severity, message) end

  local tree, syntax = json.parse(text)
  if not tree then
    ---@cast syntax core.project_actions.SyntaxError
    report(syntax.offset, syntax.offset + 1, "error", syntax.message)
    return nil, problems
  end

  ---@param node core.project_actions.Node
  ---@param fields core.project_actions.Field[]
  ---@param where string
  ---@return table<string, core.project_actions.Node>
  local function fields_of(node, fields, where)
    local found, seen = {}, {}
    local known = table.concat(vim.tbl_map(function(field) return field.name end, fields), ", ")
    for _, entry in ipairs(node.entries) do
      local name = entry.key.value --[[@as string]]
      local field = M.field(fields, name)
      if not field then
        at(entry.key, "error", ("Unknown key %q %s. Known keys: %s"):format(name, where, known))
      else
        if seen[name] then at(entry.key, "warning", ("%q is set twice; the last one wins"):format(name)) end
        seen[name] = true
        if matches(field.kind, entry.value.kind) then
          found[name] = entry.value
        else
          found[name] = nil
          at(entry.value, "error", ("%q must be %s"):format(name, M.describe(field.kind)))
        end
      end
    end
    for _, field in ipairs(fields) do
      if field.required and not seen[field.name] then
        at_brace(node, "error", ("Missing %q, %s"):format(field.name, M.describe(field.kind)))
      end
    end
    return found
  end

  ---@param path string
  ---@param cwd string
  local function resolve(path, cwd)
    path = vim.fs.normalize(path)
    if path:sub(1, 1) == "/" then return path end
    return vim.fs.normalize(vim.fs.joinpath(cwd, path))
  end

  ---@param node core.project_actions.Node
  ---@param program string
  ---@param cwd string
  ---@param shell boolean
  local function check_program(node, program, cwd, shell)
    if program:find("/", 1, true) then
      local path = resolve(program, cwd)
      local stat = vim.uv.fs_stat(path)
      if not stat then
        at(node, "warning", ("No such file: %s"):format(vim.fn.fnamemodify(path, ":~")))
      elseif stat.type == "directory" then
        at(node, "warning", ("%s is a directory"):format(vim.fn.fnamemodify(path, ":~")))
      elseif vim.fn.executable(path) ~= 1 then
        at(node, "warning", ("%s is not executable; chmod +x it"):format(vim.fn.fnamemodify(path, ":~")))
      end
    elseif not shell and vim.fn.executable(program) ~= 1 then
      at(node, "warning", ("%s is not on PATH"):format(program))
    end
  end

  ---@param node core.project_actions.Node
  ---@param cwd string
  ---@return string[]?
  local function command(node, cwd)
    if node.kind == "string" then
      local line = node.value --[[@as string]]
      local program = line:match "^%s*(%S+)"
      if not program then
        at(node, "error", "The command is empty")
        return nil
      end
      check_program(node, program, cwd, true)
      return { "sh", "-c", line }
    end
    if #node.items == 0 then
      at(node, "error", "The command list is empty")
      return nil
    end
    local argv = {}
    for _, item in ipairs(node.items) do
      if item.kind ~= "string" then
        at(item, "error", "Each part of the command is a string")
        return nil
      end
      argv[#argv + 1] = item.value
    end
    if vim.trim(argv[1]) == "" then
      at(node.items[1], "error", "The program is empty")
      return nil
    end
    check_program(node.items[1], argv[1], cwd, false)
    return argv
  end

  local labels = {}

  ---@param node core.project_actions.Node
  ---@param index integer
  ---@return core.project_actions.Entry?
  local function check_action(node, index)
    if node.kind ~= "object" then
      at(node, "error", 'Each action is an object: { "label": …, "category": …, "cmd": … }')
      return nil
    end
    local first = #problems + 1
    local f = fields_of(node, M.ACTION, "in an action")
    local entry = { label = ("Action %d"):format(index), cwd = root, queue = true }

    if f.label then
      local label = vim.trim(f.label.value --[[@as string]])
      if label == "" then
        at(f.label, "error", "The label is empty")
      else
        if labels[label] then at(f.label, "error", "Another action already has this label") end
        entry.label = label
      end
      labels[label] = true
    end

    if f.category then
      local category = f.category.value --[[@as string]]
      if vim.list_contains(M.CATEGORIES, category) then
        entry.category = category
        if category == "Run" and not f.queue then
          at(f.category, "hint", 'A Run action waits in the build queue; add "queue": false if it keeps running')
        end
      else
        at(f.category, "error", ("Unknown category %q. Use one of: %s"):format(category, table.concat(M.CATEGORIES, ", ")))
      end
    end

    entry.description = f.description and f.description.value --[[@as string?]]
    entry.errorformat = f.errorformat and f.errorformat.value --[[@as string?]]
    if f.queue then entry.queue = f.queue.value --[[@as boolean]] end

    if f.cwd then
      entry.cwd = resolve(vim.fn.expand(f.cwd.value --[[@as string]]), root)
      if vim.fn.isdirectory(entry.cwd) ~= 1 then
        at(f.cwd, "warning", ("No such directory: %s"):format(vim.fn.fnamemodify(entry.cwd, ":~")))
      end
    end

    if f.env then
      entry.env = {}
      for _, variable in ipairs(f.env.entries) do
        if variable.value.kind == "string" then
          entry.env[variable.key.value] = variable.value.value
        else
          at(variable.value, "error", "Environment values are strings")
        end
      end
    end

    if f.cmd then entry.cmd = command(f.cmd, entry.cwd) end

    for i = first, #problems do
      if problems[i].severity == "error" then
        entry.problem = ("line %d: %s"):format(problems[i].line, problems[i].message)
        break
      end
    end
    return entry
  end

  if tree.kind ~= "object" then
    at(tree, "error", 'The file is one object: { "actions": [ … ] }')
    return nil, problems
  end
  local f = fields_of(tree, M.TOP, "at the top level")
  local config = { actions = {} }
  if f.actions then
    if #f.actions.items == 0 then at(f.actions, "hint", "No actions yet") end
    for index, item in ipairs(f.actions.items) do
      config.actions[#config.actions + 1] = check_action(item, index)
    end
  end
  return config, problems
end

return M
