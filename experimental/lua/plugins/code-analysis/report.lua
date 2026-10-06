local api = require "plugins.code-analysis.api"
local html = require "plugins.code-analysis.html"

local M = {}

local severity = vim.diagnostic.severity

local SEVERITIES = {
  BLOCKER = { rank = 1, level = severity.ERROR, label = "Blocker" },
  HIGH = { rank = 2, level = severity.ERROR, label = "High" },
  CRITICAL = { rank = 2, level = severity.ERROR, label = "Critical" },
  MEDIUM = { rank = 3, level = severity.WARN, label = "Medium" },
  MAJOR = { rank = 3, level = severity.WARN, label = "Major" },
  LOW = { rank = 4, level = severity.INFO, label = "Low" },
  MINOR = { rank = 4, level = severity.INFO, label = "Minor" },
  INFO = { rank = 5, level = severity.HINT, label = "Info" },
}

local SECTIONS = {
  introduction = { order = 1 },
  root_cause = { order = 2, title = "Why is this an issue?" },
  assess_the_problem = { order = 3, title = "What is the potential impact?" },
  how_to_fix = { order = 4, title = "How can I fix it?" },
  resources = { order = 5, title = "Resources" },
}

local PAGE_SIZE = 500
local MAX_PAGES = 20
local NEARBY = 5
local ANALYSIS_TIMEOUT = 300

local function notify(message, level) vim.notify(message, level or vim.log.levels.INFO, { title = "Sonar" }) end

---@param root string
---@return string? branch
local function current_branch(root)
  local ok, result = pcall(
    function()
      return vim.system({ "git", "-C", root, "symbolic-ref", "--short", "-q", "HEAD" }, { text = true }):wait(3000)
    end
  )
  if not ok or result.code ~= 0 then return end
  local branch = vim.trim(result.stdout or "")
  return branch ~= "" and branch or nil
end

---@param root string
---@param args string[]
---@return string[]?
local function git_lines(root, args)
  local ok, result = pcall(
    function() return vim.system(vim.list_extend({ "git", "-C", root }, args), { text = true }):wait(5000) end
  )
  if not ok or result.code ~= 0 then return end
  return vim.split(result.stdout or "", "\n", { trimempty = true })
end

---@param root string
---@return string[]
local function tracked_files(root)
  local result = vim.system({ "git", "-C", root, "ls-files" }, { text = true }):wait(5000)
  return result.code == 0 and vim.split(result.stdout or "", "\n", { trimempty = true }) or {}
end

---@param root string
---@return fun(path: string): string?
local function path_resolver(root)
  local tracked
  return function(path)
    local direct = vim.fs.joinpath(root, path)
    if vim.uv.fs_stat(direct) then return direct end
    tracked = tracked or tracked_files(root)
    local suffix = "/" .. path
    for _, file in ipairs(tracked) do
      if vim.endswith(file, suffix) then return vim.fs.joinpath(root, file) end
    end
  end
end

---@param issue table
---@return table
local function worst_impact(issue)
  local worst
  for _, impact in ipairs(issue.impacts or {}) do
    local candidate = SEVERITIES[impact.severity]
    if candidate and (not worst or candidate.rank < worst.severity.rank) then
      worst = { severity = candidate, quality = impact.softwareQuality }
    end
  end
  return worst or { severity = SEVERITIES[issue.severity] or SEVERITIES.INFO, quality = issue.type }
end

---@param quality? string
---@return string?
local function titlecase(quality) return quality and (quality:sub(1, 1) .. quality:sub(2):lower():gsub("_", " ")) or nil end

---@param rule table?
---@return string[]
local function describe(rule)
  if not rule then return { "", "*The rule could not be fetched.*" } end
  local sections = vim.deepcopy(rule.descriptionSections or {})
  if #sections == 0 and rule.htmlDesc then sections = { { key = "introduction", content = rule.htmlDesc } } end
  if #sections == 0 then
    return { "", "*The server sent no description; it hides them from requests without a token.*" }
  end
  table.sort(sections, function(a, b)
    local left, right = SECTIONS[a.key] or { order = 9 }, SECTIONS[b.key] or { order = 9 }
    return left.order < right.order
  end)

  local lines, titled = {}, {}
  for _, section in ipairs(sections) do
    local title = (SECTIONS[section.key] or {}).title
    if title and not titled[title] and not (section.content or ""):match "^%s*<h2" then
      titled[title] = true
      vim.list_extend(lines, { "", "## " .. title })
    end
    if section.context and section.context.displayName then
      vim.list_extend(lines, { "", "### " .. section.context.displayName })
    end
    table.insert(lines, "")
    vim.list_extend(lines, html.to_markdown(section.content or "", rule.lang))
  end
  return lines
end

---@param issue table
---@param impact table
---@param path string
---@param rule table?
---@return string[]
local function preview_lines(issue, impact, path, rule)
  local lines = {
    "# " .. issue.message,
    "",
    ("`%s` %s"):format(issue.rule, rule and rule.name or ""),
    "",
  }
  local impacts = issue.impacts or {}
  if #impacts == 0 then impacts = { { softwareQuality = impact.quality, severity = issue.severity } } end
  for _, entry in ipairs(impacts) do
    local level = SEVERITIES[entry.severity] or impact.severity
    lines[#lines + 1] = ("- %s: **%s**"):format(titlecase(entry.softwareQuality) or "Impact", level.label)
  end
  if issue.effort then lines[#lines + 1] = ("- Effort: %s"):format(issue.effort) end
  vim.list_extend(lines, { "", ("%s:%d"):format(path, issue.line or 1) })
  vim.list_extend(lines, describe(rule))
  return lines
end

---@param key string
---@param pull_request string
---@return table[]? issues, table<string, string>? paths, string? err
local function fetch_issues(key, pull_request)
  local issues, paths = {}, {}
  for page = 1, MAX_PAGES do
    local response = api.await("api/issues/search", {
      components = key,
      pullRequest = pull_request,
      resolved = "false",
      ps = PAGE_SIZE,
      p = page,
    })
    if not response.ok then return nil, nil, response.err end
    vim.list_extend(issues, response.body.issues or {})
    for _, component in ipairs(response.body.components or {}) do
      if component.path then paths[component.key] = component.path end
    end
    local total = response.body.paging and response.body.paging.total or response.body.total or 0
    if page * PAGE_SIZE >= total then break end
  end
  return issues, paths
end

---@param issues table[]
---@return table<string, table>
local function fetch_rules(issues)
  local keys, seen = {}, {}
  for _, issue in ipairs(issues) do
    if not seen[issue.rule] then
      seen[issue.rule] = true
      keys[#keys + 1] = issue.rule
    end
  end
  local requests = vim.tbl_map(function(rule) return { "api/rules/show", { key = rule } } end, keys)
  local rules = {}
  for index, response in ipairs(api.await_all(requests)) do
    if response.ok and response.body.rule then rules[keys[index]] = response.body.rule end
  end
  return rules
end

---@param status table?
---@return string
local function gate_summary(status)
  if not status or not status.status or status.status == "NONE" then return "no quality gate" end
  if status.status == "OK" then return "quality gate passed" end
  local failed = {}
  for _, condition in ipairs(status.conditions or {}) do
    if condition.status == "ERROR" then
      failed[#failed + 1] = ("%s %s"):format((condition.metricKey:gsub("_", " ")), condition.actualValue or "")
    end
  end
  return "quality gate failed" .. (#failed > 0 and (": " .. table.concat(failed, ", ")) or "")
end

---@param pull_requests table[]
---@param branch string
---@return table?
local function pull_request_for(pull_requests, branch)
  local found
  for _, pull_request in ipairs(pull_requests) do
    if
      pull_request.branch == branch and (not found or (pull_request.analysisDate or "") > (found.analysisDate or ""))
    then
      found = pull_request
    end
  end
  return found
end

---@class plugins.analysis.Report
---@field branch string
---@field title string
---@field fetched_at integer
---@field items table[]
---@field base? string
---@field dirty? string[]

---@param root string
---@param branch string
---@return string
local function cache_path(root, branch)
  local directory = vim.fs.joinpath(vim.fn.stdpath "state" --[[@as string]], "sonar")
  return vim.fs.joinpath(directory, vim.fs.slug(root .. "@" .. branch) .. ".json")
end

---@param root string
---@param report plugins.analysis.Report
local function save(root, report)
  local path = cache_path(root, report.branch)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile({ vim.json.encode(report) }, path)
end

---@param root string
---@param branch string
---@return plugins.analysis.Report?
local function load(root, branch)
  local path = cache_path(root, branch)
  if not vim.uv.fs_stat(path) then return end
  local ok, report = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  return ok and type(report) == "table" and report or nil
end

---@param seconds integer
---@return string
local function age(seconds)
  if seconds < 60 then return "just now" end
  if seconds < 3600 then return ("%d min ago"):format(seconds / 60) end
  if seconds < 86400 then return ("%d h ago"):format(seconds / 3600) end
  return ("%d d ago"):format(seconds / 86400)
end

---@param live vim.Diagnostic[]
---@param taken table<integer, true>
---@param item table
---@param accept fun(diagnostic: vim.Diagnostic): boolean
---@return boolean
local function claim(live, taken, item, accept)
  local best, distance
  for index, diagnostic in ipairs(live) do
    if not taken[index] and diagnostic.code == item.item.code and accept(diagnostic) then
      local gap = math.abs(diagnostic.lnum + 1 - item.pos[1])
      if not distance or gap < distance then
        best, distance = index, gap
      end
    end
  end
  if best then taken[best] = true end
  return best ~= nil
end

-- Messages name the symbol, so rule and message survive lines moving under an
-- edit; a reworded message from a different analyzer version falls back to the
-- same rule a few lines away.
---@param bufnr integer
---@param reported table[]
local function mark_file(bufnr, reported)
  local live = require("plugins.code-analysis.control").diagnostics(bufnr)
  local taken = {}
  local unmatched = {}
  for _, item in ipairs(reported) do
    local message = item.message or item.item.message
    local same = function(diagnostic) return diagnostic.message:gsub(" %[%+%d+ locations?%]$", "") == message end
    if not claim(live, taken, item, same) then unmatched[#unmatched + 1] = item end
  end
  for _, item in ipairs(unmatched) do
    item.fixed = not claim(
      live,
      taken,
      item,
      function(diagnostic) return math.abs(diagnostic.lnum + 1 - item.pos[1]) <= NEARBY end
    )
  end
end

-- The local analysis disagrees with CI on some rules -- it sees a different
-- build -- so only a file that changed since the fetch can have fixed anything.
---@param root string
---@param report plugins.analysis.Report
---@return table<string, true>
local function changed_files(root, report)
  local changed = {}
  local names = git_lines(root, { "diff", "--name-only", report.base or "HEAD" }) or {}
  vim.list_extend(names, report.dirty or {})
  for _, name in ipairs(names) do
    changed[vim.fs.joinpath(root, name)] = true
  end
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[bufnr].modified then changed[vim.api.nvim_buf_get_name(bufnr)] = true end
  end
  return changed
end

---@param items table[]
---@param changed table<string, true>
---@return integer fixed
local function mark_fixed(items, changed)
  local control = require "plugins.code-analysis.control"
  local by_buffer = {}
  for _, item in ipairs(items) do
    local bufnr = item.file and changed[item.file] and vim.fn.bufnr(item.file) or -1
    if bufnr > 0 and control.analysed(bufnr) then
      by_buffer[bufnr] = by_buffer[bufnr] or {}
      table.insert(by_buffer[bufnr], item)
    end
  end
  for bufnr, reported in pairs(by_buffer) do
    mark_file(bufnr, reported)
  end
  return #vim.tbl_filter(function(item) return item.fixed end, items)
end

---@param item table
---@param picker snacks.Picker
---@return snacks.picker.Highlight[]
local function format(item, picker)
  local chunks = require("snacks").picker.format.diagnostic(item, picker)
  if not item.fixed then return chunks end
  for _, chunk in ipairs(chunks) do
    if type(chunk[1]) == "string" then chunk[2] = "SnacksPickerDimmed" end
  end
  table.insert(chunks, 1, { "✓ ", "DiagnosticOk" })
  return chunks
end

---@param root string
---@param report plugins.analysis.Report
local function show(root, report)
  local title = ("Sonar %s · fetched %s"):format(report.title, age(os.time() - report.fetched_at))
  if #report.items == 0 then return notify(title .. " · no open issues") end
  local items = vim.deepcopy(report.items)
  local fixed = mark_fixed(items, changed_files(root, report))
  if fixed > 0 then title = title .. (" · %d fixed locally"):format(fixed) end
  for index, item in ipairs(items) do
    item.order = index + (item.fixed and #items or 0)
  end
  table.sort(items, function(a, b) return a.order < b.order end)

  require("snacks").picker {
    title = title,
    items = items,
    format = format,
    focus = "list",
    sort = { fields = { "score:desc", "idx" } },
    matcher = { sort_empty = true },
    preview = function(ctx)
      local lines = ctx.item.why
      if ctx.item.fixed then
        lines = vim.list_extend({ "> ✓ Fixed locally: Sonar no longer reports this in the file.", "" }, lines)
      end
      ctx.preview:reset()
      ctx.preview:set_lines(lines)
      ctx.preview:highlight { ft = "markdown" }
      ctx.preview:wo { wrap = true, linebreak = true }
    end,
  }
end

---@param root string
---@param issues table[]
---@param paths table<string, string>
---@return table[]
local function picker_items(root, issues, paths)
  local rules = fetch_rules(issues)
  local resolve = path_resolver(root)
  local items = {}
  for _, issue in ipairs(issues) do
    local path = paths[issue.component] or issue.component:gsub("^[^:]*:", "")
    local file = resolve(path)
    local impact = worst_impact(issue)
    local range = issue.textRange or {}
    items[#items + 1] = {
      text = table.concat({ path, issue.rule, issue.message }, " "),
      file = file,
      pos = { issue.line or range.startLine or 1, range.startOffset or 0 },
      severity = impact.severity.level,
      rank = impact.severity.rank,
      path = path,
      message = issue.message,
      item = {
        message = file and issue.message or (issue.message .. " (not in this checkout)"),
        source = titlecase(impact.quality),
        code = issue.rule,
      },
      why = preview_lines(issue, impact, file and vim.fs.relpath(root, file) or path, rules[issue.rule]),
    }
  end
  table.sort(items, function(a, b)
    if a.rank ~= b.rank then return a.rank < b.rank end
    if a.path ~= b.path then return a.path < b.path end
    return a.pos[1] < b.pos[1]
  end)
  return items
end

---@param root string
---@param key string
---@param branch string
local function fetch(root, key, branch)
  local listed = api.await("api/project_pull_requests/list", { project = key })
  if not listed.ok then
    if listed.status == 404 then
      return notify(
        "The server does not report pull requests -- Community Build needs the branch plugin for that",
        vim.log.levels.WARN
      )
    end
    return notify("Cannot list pull requests: " .. listed.err, vim.log.levels.ERROR)
  end
  local pull_request = pull_request_for(listed.body.pullRequests or {}, branch)
  if not pull_request then return notify(("No PR for %s on SonarQube"):format(branch)) end

  local gate = api.await("api/qualitygates/project_status", { projectKey = key, pullRequest = pull_request.key })
  local issues, paths, err = fetch_issues(key, pull_request.key)
  if not issues then return notify("Cannot fetch the PR's issues: " .. err, vim.log.levels.ERROR) end

  ---@type plugins.analysis.Report
  local report = {
    branch = branch,
    title = ("PR #%s · %s"):format(pull_request.key, gate_summary(gate.ok and gate.body.projectStatus or nil)),
    fetched_at = os.time(),
    items = picker_items(root, issues, paths or {}),
    base = (git_lines(root, { "rev-parse", "HEAD" }) or {})[1],
    dirty = git_lines(root, { "diff", "--name-only", "HEAD" }),
  }
  save(root, report)
  show(root, report)
end

---@param body fun(branch: string)
---@param root string
local function on_branch(body, root)
  local branch = current_branch(root)
  if not branch then return notify("No PR: HEAD is not on a branch", vim.log.levels.WARN) end
  coroutine.wrap(function()
    local ok, err = xpcall(body, debug.traceback, branch)
    if not ok then notify(err, vim.log.levels.ERROR) end
  end)()
end

---@param root string
---@param key string
function M.open(root, key)
  on_branch(function(branch) fetch(root, key, branch) end, root)
end

-- Only the action asks the server; this shows what it last brought back, and
-- fetches only when there is nothing yet for this branch.
---@param root string
---@param key string
function M.cached(root, key)
  on_branch(function(branch)
    local report = load(root, branch)
    if report then return show(root, report) end
    fetch(root, key, branch)
  end, root)
end

---@param ms integer
local function sleep(ms)
  local co = coroutine.running()
  vim.defer_fn(function() coroutine.resume(co) end, ms)
  coroutine.yield()
end

---@param root string
---@param report plugins.analysis.Report
---@return integer[]? waiting
local function load_files(root, report)
  local control = require "plugins.code-analysis.control"
  local changed = changed_files(root, report)
  local waiting, seen = {}, {}
  for _, item in ipairs(report.items) do
    if item.file and changed[item.file] and not seen[item.file] then
      seen[item.file] = true
      local bufnr = vim.fn.bufadd(item.file)
      if not vim.api.nvim_buf_is_loaded(bufnr) then vim.fn.bufload(bufnr) end
      if control.handles(bufnr) and not control.analysed(bufnr) then waiting[#waiting + 1] = bufnr end
    end
  end
  return next(seen) and waiting or nil
end

-- Sonar analyses only what is open, so the changed files are loaded as hidden
-- buffers and stay loaded: unloading one would throw its analysis away again.
---@param root string
function M.reanalyse(root)
  local control = require "plugins.code-analysis.control"
  on_branch(function(branch)
    local report = load(root, branch)
    if not report then return notify(("No saved report for %s; fetch it first"):format(branch), vim.log.levels.WARN) end
    local waiting = load_files(root, report)
    if not waiting then
      notify "No file in the report has changed since it was fetched"
      return show(root, report)
    end
    if #waiting > 0 then notify(("Analysing %d file%s..."):format(#waiting, #waiting == 1 and "" or "s")) end
    local deadline = os.time() + ANALYSIS_TIMEOUT
    while os.time() < deadline do
      waiting = vim.tbl_filter(
        function(bufnr) return vim.api.nvim_buf_is_valid(bufnr) and not control.analysed(bufnr) end,
        waiting
      )
      if #waiting == 0 then break end
      sleep(500)
    end
    if #waiting > 0 then
      notify(
        ("%d file%s not analysed in time; left unchecked"):format(#waiting, #waiting == 1 and "" or "s"),
        vim.log.levels.WARN
      )
    end
    show(root, report)
  end, root)
end

return M
