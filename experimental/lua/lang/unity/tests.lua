local editor = require "lang.unity.editor"
local messenger = require "lang.unity.messenger"
local project = require "lang.unity.project"

local M = {}

--- `TestStatusAdaptor` from `Editor/Testing/TestStatusAdaptor.cs`. `JsonUtility`
--- serialises an enum as its integer value, so this is the mapping.
local STATUS = { [0] = "Passed", [1] = "Skipped", [2] = "Inconclusive", [3] = "Failed" }

M.MODES = { "EditMode", "PlayMode" }

---@class unity.TestResult
---@field name string
---@field status string|nil
---@field state string|nil
---@field stack string|nil

---@type { mode: string, filter: string, root: string, results: unity.TestResult[], started: integer }|nil
local run

---@param message string
---@param level? integer
local function notify(message, level) vim.notify(message, level or vim.log.levels.INFO, { title = "Unity" }) end

---@param value string
---@return table|nil
local function decode(value)
  local ok, decoded = pcall(vim.json.decode, value)
  return ok and decoded or nil
end

---@param trace string|nil
---@param root string
---@return string|nil file
---@return integer|nil line
local function first_project_frame(trace, root)
  if not trace or trace == "" then return nil, nil end
  local fallback_file, fallback_line
  for file, line in trace:gmatch "in%s+([^\r\n:]+):(%d+)" do
    if vim.startswith(file, root) then return file, tonumber(line) end
    fallback_file = fallback_file or file
    fallback_line = fallback_line or tonumber(line)
  end
  return fallback_file, fallback_line
end

---@param results unity.TestResult[]
---@return integer passed
---@return integer failed
---@return integer skipped
local function tally(results)
  local passed, failed, skipped = 0, 0, 0
  for _, result in ipairs(results) do
    if result.status == "Passed" then
      passed = passed + 1
    elseif result.status == "Failed" then
      failed = failed + 1
    elseif result.status then
      skipped = skipped + 1
    end
  end
  return passed, failed, skipped
end

---@param failures unity.TestResult[]
---@param root string
local function show_failures(failures, root)
  local items = {}
  for _, result in ipairs(failures) do
    local file, line = first_project_frame(result.stack, root)
    local state = (result.state or "Failed"):gsub("%s+", " ")
    items[#items + 1] = {
      text = result.name .. " " .. state,
      file = file or (root .. "/Assets"),
      pos = { line or 1, 0 },
      severity = vim.diagnostic.severity.ERROR,
      item = { message = state, source = "Unity", code = result.name },
    }
  end

  require("snacks").picker {
    title = "Unity test failures",
    items = items,
    format = "diagnostic",
    matcher = { sort_empty = true },
  }
end

local function report()
  if not run then return end
  local finished = run
  run = nil
  messenger.keepalive_stop()

  local passed, failed, skipped = tally(finished.results)
  local elapsed = (vim.uv.now() - finished.started) / 1000
  local summary = ("%s: %d passed, %d failed, %d skipped in %.1fs"):format(
    finished.mode,
    passed,
    failed,
    skipped,
    elapsed
  )

  local failures = vim.tbl_filter(function(result) return result.status == "Failed" end, finished.results)
  if vim.tbl_isempty(failures) then return notify(summary) end

  notify(summary, vim.log.levels.ERROR)
  show_failures(failures, finished.root)
end

local wired = false

--- Attached on the first run rather than at startup, so a session that never
--- touches Unity never opens the messenger's socket.
local function wire()
  if wired then return end
  wired = true

  messenger.on(messenger.TYPE.RunStarted, function()
    if run then notify(("Running %s tests..."):format(run.mode)) end
  end)

  messenger.on(messenger.TYPE.TestFinished, function(value)
    if not run then return end
    local decoded = decode(value)
    local adaptors = decoded and decoded.TestResultAdaptors
    -- A suite reports itself alongside its children; only the leaf carries a
    -- result worth counting.
    if not adaptors or #adaptors ~= 1 then return end
    local adaptor = adaptors[1]
    run.results[#run.results + 1] = {
      name = adaptor.FullName or adaptor.Name,
      status = STATUS[adaptor.TestStatus],
      state = adaptor.ResultState,
      stack = adaptor.StackTrace,
    }
  end)

  messenger.on(messenger.TYPE.RunFinished, report)
end

---@return boolean
function M.running() return run ~= nil end

---@param mode string `"EditMode"` or `"PlayMode"`
---@param filter? string An NUnit full name, or `""` for everything in `mode`.
function M.run(mode, filter)
  local root = project.require_root()
  if not root then return end
  local instance = editor.require_for_project(root)
  if not instance then return end
  if run then return notify("A test run is already in flight", vim.log.levels.WARN) end

  wire()
  -- `TestRunnerApiListener.ExecuteTests` splits on the first colon and returns
  -- without a word when there is none.
  local value = ("%s:%s"):format(mode, filter or "")
  messenger.send_checked(instance, messenger.TYPE.ExecuteTests, value, function()
    run = { mode = mode, filter = filter or "", root = root, results = {}, started = vim.uv.now() }
    messenger.keepalive_start(instance)
  end)
end

---@param mode string
function M.pick(mode)
  local root = project.require_root()
  if not root then return end
  local instance = editor.require_for_project(root)
  if not instance then return end

  wire()

  local answered = false
  local off ---@type fun()|nil
  off = messenger.on(messenger.TYPE.TestListRetrieved, function(value)
    if answered then return end
    local list_mode, json = value:match "^(%w+):(.*)$"
    if list_mode ~= mode then return end
    answered = true
    if off then off() end

    local decoded = decode(json)
    local tests = {}
    for _, adaptor in ipairs(decoded and decoded.TestAdaptors or {}) do
      -- Leaves only: an assembly or a suite has no `Method`.
      if adaptor.Method and adaptor.FullName then tests[#tests + 1] = adaptor.FullName end
    end
    table.sort(tests)

    if vim.tbl_isempty(tests) then return notify(("No %s tests found"):format(mode), vim.log.levels.WARN) end

    local everything = ("<all %s tests>"):format(mode)
    table.insert(tests, 1, everything)
    vim.ui.select(tests, { prompt = "Run which test?" }, function(choice)
      if choice then M.run(mode, choice ~= everything and choice or "") end
    end)
  end)

  messenger.send_checked(instance, messenger.TYPE.RetrieveTestList, mode)
end

--- The NUnit full name of the test the cursor is in, or the reason there is
--- none -- "no parser installed" and "not in a test" are different problems and
--- an action that says only the second one sends you looking in the wrong place.
---@param bufnr? integer
---@return string|nil name
---@return string|nil reason
function M.at_cursor(bufnr)
  bufnr = bufnr or 0
  if vim.bo[bufnr].filetype ~= "cs" then return nil, "The buffer is not C#" end

  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "c_sharp")
  if not ok or not parser then return nil, "No c_sharp treesitter parser is installed" end
  local tree = parser:parse()[1]
  if not tree then return nil, "The buffer has not parsed yet" end

  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local node = tree:root():named_descendant_for_range(row - 1, col, row - 1, col)

  ---@param declaration TSNode
  ---@return string|nil
  local function name_of(declaration)
    local field = declaration:field "name"
    return field[1] and vim.treesitter.get_node_text(field[1], bufnr) or nil
  end

  local parts, method = {}, nil
  while node do
    local type = node:type()
    if type == "method_declaration" then
      -- The innermost wins: a local function inside a test is still that test.
      method = method or name_of(node)
    elseif
      type == "class_declaration"
      or type == "namespace_declaration"
      or type == "file_scoped_namespace_declaration"
    then
      local name = name_of(node)
      if name then table.insert(parts, 1, name) end
    end
    node = node:parent()
  end

  if not method then return nil, "The cursor is not inside a test method" end
  parts[#parts + 1] = method
  return table.concat(parts, "."), nil
end

---@param mode string
function M.run_at_cursor(mode)
  local name, reason = M.at_cursor()
  if not name then return notify(reason or "No test under the cursor", vim.log.levels.WARN) end
  M.run(mode, name)
end

return M
