-- Running Unity's tests from Neovim, with the failures in the quickfix list.
--
-- This rides on the same UDP channel as Play/Pause -- see
-- `user.unity_messenger` for the protocol and for why Unity has to be told
-- Neovim is its script editor before any of it works. Unity's Test Framework
-- does the running; we ask for a list, ask for a run, and read the results back
-- as they arrive.
--
-- THE FOUR MESSAGES:
--
--     RetrieveTestList  "EditMode"                -> TestListRetrieved "EditMode:{json}"
--     ExecuteTests      "EditMode:Some.Test.Name" -> RunStarted {json}
--                                                    TestStarted / TestFinished {json} per test
--                                                    RunFinished {json}
--
-- The JSON is `JsonUtility.ToJson` over the adaptor types in
-- `Editor/Testing/`, and it is *flattened*: a tree of suites and tests arrives
-- as one array where each element points at its parent by index, with the root
-- at index 0 carrying `Parent: -1`. So a "test" is an element with a `Method`,
-- and its display name is already in `FullName`.
--
-- WHY THE RESULTS COME BACK OVER TCP. A test list for a real project is far
-- more than the 8 KB a datagram carries, so Unity switches to its one-shot TCP
-- mode for the big ones. `user.unity_messenger` handles that transparently --
-- worth knowing only because it explains why `TestListRetrieved` can take a
-- beat longer to arrive than everything else.
--
-- WHY A KEEPALIVE. Unity forgets a client after four seconds of silence and
-- only broadcasts run events to clients it remembers, so a run that outlasts
-- that would report `RunStarted` and then nothing at all. The keepalive is
-- started with the run and stopped when it finishes.

local messenger = require "user.integrations.unity.messenger"

local M = {}

--- `TestStatusAdaptor` from `Editor/Testing/TestStatusAdaptor.cs`. `JsonUtility`
--- serialises enums as their integer value, so this is the mapping.
local STATUS = { [0] = "Passed", [1] = "Skipped", [2] = "Inconclusive", [3] = "Failed" }

M.MODES = { "EditMode", "PlayMode" }

--- The run currently in flight, if any.
---@type { mode: string, filter: string, results: table[], started: number }|nil
local run = nil

---@param value string
---@return table|nil
local function decode(value)
  local ok, decoded = pcall(vim.json.decode, value)
  if not ok then return nil end
  return decoded
end

--- Pull the first source location out of a Mono stack trace.
---
--- Mono's format is
---     at Fixture.TestName () [0x0002a] in /abs/path/Tests/Foo.cs:41
--- and the frame we want is the first one inside the project, which -- because
--- the assertion helpers are in NUnit, not in your code -- is not always the
--- top frame. Take the first frame whose file is under `root`.
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

--- Turn a finished run into a quickfix list and a one-line summary.
---@param root string
local function report(root)
  if not run then return end

  local failures = {}
  for _, result in ipairs(run.results) do
    if result.status == "Failed" then
      local file, line = first_project_frame(result.stack, root)
      table.insert(failures, {
        filename = file or (root .. "/Assets"),
        lnum = line or 1,
        col = 1,
        type = "E",
        text = ("%s -- %s"):format(result.name, (result.state or "Failed"):gsub("%s+", " ")),
      })
    end
  end

  local passed, failed, skipped = 0, 0, 0
  for _, result in ipairs(run.results) do
    if result.status == "Passed" then
      passed = passed + 1
    elseif result.status == "Failed" then
      failed = failed + 1
    elseif result.status then
      skipped = skipped + 1
    end
  end

  local elapsed = (vim.uv.now() - run.started) / 1000
  local summary = ("%s: %d passed, %d failed, %d skipped in %.1fs"):format(run.mode, passed, failed, skipped, elapsed)

  if #failures > 0 then
    vim.fn.setqflist({}, " ", { title = "Unity " .. run.mode .. " tests", items = failures })
    -- Not `copen`: `æq` / `øq` (`]q` / `[q`) walk the list without a window in
    -- the way, which is how the rest of this config treats compiler output.
    vim.notify(
      summary .. "\n" .. "Failures are in the quickfix list (æq / øq).",
      vim.log.levels.ERROR,
      { title = "Unity" }
    )
  else
    vim.notify(summary, vim.log.levels.INFO, { title = "Unity" })
  end

  run = nil
  messenger.keepalive_stop()
end

--- Whether the result listeners are attached. There is no way to unsubscribe
--- from `user.unity_messenger` and no reason to want one, so this is a latch
--- rather than a toggle.
local wired = false

--- Attach the result listeners. Called by `M.run` / `M.pick` rather than at
--- startup: nothing here costs anything until a run happens, and this way a
--- session that never touches Unity never touches the messenger either.
function M.setup()
  if wired then return end
  wired = true

  messenger.on(messenger.TYPE.RunStarted, function()
    if run then vim.notify(("Running %s tests..."):format(run.mode), vim.log.levels.INFO, { title = "Unity" }) end
  end)

  messenger.on(messenger.TYPE.TestFinished, function(value)
    if not run then return end
    local decoded = decode(value)
    local adaptors = decoded and decoded.TestResultAdaptors
    if not adaptors then return end
    -- Index 0 of the flattened array is the node this event is about; its
    -- children follow. A leaf (a single test) is the only thing with no
    -- children, and for a suite-level event we would double-count, so only
    -- record when the event carries exactly one adaptor.
    if #adaptors ~= 1 then return end
    local adaptor = adaptors[1]
    table.insert(run.results, {
      name = adaptor.FullName or adaptor.Name,
      status = STATUS[adaptor.TestStatus],
      state = adaptor.ResultState,
      stack = adaptor.StackTrace,
    })
  end)

  messenger.on(messenger.TYPE.RunFinished, function()
    local root = require("user.integrations.unity").root()
    if run and root then report(root) end
  end)
end

--- Run tests. `filter` is an NUnit full name, or `""` for everything in `mode`.
---@param mode string `"EditMode"` or `"PlayMode"`
---@param filter? string
function M.run(mode, filter)
  M.setup()
  local root = require("user.integrations.unity").require_root()
  if not root then return end
  local instance = require("user.integrations.unity.editor").require_for_project(root)
  if not instance then return end

  if run then
    vim.notify("A test run is already in flight", vim.log.levels.WARN, { title = "Unity" })
    return
  end

  -- `ExecuteTests` wants exactly `TestMode:FullName`, and it silently returns
  -- if there is no colon (`TestRunnerApiListener.ExecuteTests`).
  local value = ("%s:%s"):format(mode, filter or "")
  messenger.send_checked(instance, messenger.TYPE.ExecuteTests, value, function()
    run = { mode = mode, filter = filter or "", results = {}, started = vim.uv.now() }
    messenger.keepalive_start(instance)
  end)
end

--- Ask Unity what tests exist, then run the one you pick.
---@param mode string `"EditMode"` or `"PlayMode"`
function M.pick(mode)
  M.setup()
  local root = require("user.integrations.unity").require_root()
  if not root then return end
  local instance = require("user.integrations.unity.editor").require_for_project(root)
  if not instance then return end

  -- One-shot: unsubscribe the moment the list for *our* mode arrives, or this
  -- leaks a closure per keypress. See `user.unity_messenger.on`.
  local answered = false
  local off ---@type fun()|nil
  off = messenger.on(messenger.TYPE.TestListRetrieved, function(value)
    if answered then return end
    -- `TestMode:Json`
    local list_mode, json = value:match "^(%w+):(.*)$"
    if list_mode ~= mode then return end
    answered = true
    if off then off() end

    local decoded = decode(json)
    local adaptors = decoded and decoded.TestAdaptors or {}
    local tests = {}
    for _, adaptor in ipairs(adaptors) do
      -- Only leaves: suites and assemblies have no `Method`.
      if adaptor.Method and adaptor.FullName then table.insert(tests, adaptor.FullName) end
    end
    table.sort(tests)

    if vim.tbl_isempty(tests) then
      vim.notify(("No %s tests found"):format(mode), vim.log.levels.WARN, { title = "Unity" })
      return
    end

    table.insert(tests, 1, "<all " .. mode .. " tests>")
    vim.ui.select(tests, { prompt = "Run which test?" }, function(choice)
      if not choice then return end
      M.run(mode, choice == tests[1] and "" or choice)
    end)
  end)

  messenger.send_checked(instance, messenger.TYPE.RetrieveTestList, mode)
end

--- The test under the cursor, as NUnit would name it: `Namespace.Fixture.Method`.
---
--- Derived from Treesitter rather than from Unity's list, so it works without a
--- round trip -- and so it works on a test you have only just written, which
--- Unity has not compiled yet.
---@return string|nil
function M.test_at_cursor()
  if vim.bo.filetype ~= "cs" then return nil end

  -- ASKING FOR THE PARSER BY NAME, not `vim.treesitter.get_node()`. That
  -- helper reads the parser *attached* to the buffer, which exists only once
  -- something has started highlighting it -- so it returns nil in a buffer
  -- opened but not yet drawn, and in any headless run. Naming the language
  -- creates the parser if it has to.
  local ok, parser = pcall(vim.treesitter.get_parser, 0, "c_sharp")
  if not ok or not parser then return nil end
  local tree = parser:parse()[1]
  if not tree then return nil end

  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local node = tree:root():named_descendant_for_range(row - 1, col, row - 1, col)
  if not node then return nil end

  --- The `name:` field of a declaration, as text. For a namespace that is a
  --- `qualified_name`, so `Game.Tests` comes back whole -- which is exactly
  --- what NUnit's full name wants.
  ---@param declaration TSNode
  ---@return string|nil
  local function name_of(declaration)
    local field = declaration:field "name"
    return field[1] and vim.treesitter.get_node_text(field[1], 0) or nil
  end

  local parts, method = {}, nil
  while node do
    local type = node:type()
    if type == "method_declaration" then
      -- The innermost one: a local function inside a test is still that test.
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

  if not method then return nil end
  table.insert(parts, method)
  return table.concat(parts, ".")
end

--- Run just the test the cursor is in.
---@param mode string
function M.run_at_cursor(mode)
  local name = M.test_at_cursor()
  if not name then
    vim.notify("Cursor is not inside a test method", vim.log.levels.WARN, { title = "Unity" })
    return
  end
  M.run(mode, name)
end

return M
