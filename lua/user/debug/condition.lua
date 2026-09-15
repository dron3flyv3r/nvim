-- A conditional breakpoint that tells you when it is wrong.
--
-- The plain prompt accepted anything. A typo produced a breakpoint that simply
-- never fired, and the adapter's own complaint went to nvim-dap's log file --
-- `Session:set_breakpoints` notes an unverified breakpoint at info level and
-- says nothing to the person who just set it. Here the expression is completed
-- from the paused frame, refused when it is unambiguously malformed, evaluated
-- where that is possible, and the adapter's verdict is reported out loud.
local M = {}

local CLOSERS = { [")"] = "(", ["]"] = "[" }
local OPERATOR = "[=<>!%+%-%*/%%&|%^]"

--- The mistakes worth refusing. A real C# parser is out of scope -- these are
--- the ones that are unambiguous whatever the language.
---@param condition string
---@return string|nil complaint nil when nothing is obviously wrong
function M.lint(condition)
  local text = vim.trim(condition)
  if text == "" then return "it is empty" end

  local stack, quote, escaped = {}, nil, false
  for index = 1, #text do
    local char = text:sub(index, index)
    if escaped then
      escaped = false
    elseif quote then
      if char == "\\" then
        escaped = true
      elseif char == quote then
        quote = nil
      end
    elseif char == '"' or char == "'" then
      quote = char
    elseif char == "(" or char == "[" then
      table.insert(stack, char)
    elseif CLOSERS[char] then
      if table.remove(stack) ~= CLOSERS[char] then return ("there is a `%s` with nothing to close"):format(char) end
    elseif char == "=" then
      -- `==`, `>=`, `!=` and the lambda arrow are all fine; a lone `=` assigns.
      local before, after = text:sub(index - 1, index - 1), text:sub(index + 1, index + 1)
      if not before:match(OPERATOR) and after ~= "=" and after ~= ">" then
        return "`=` assigns a value -- did you mean `==`?"
      end
    end
  end

  if quote then return "the string is never closed" end
  if #stack > 0 then return ("`%s` is never closed"):format(stack[#stack]) end
  if text:find "[%+%-%*/%%&|%^<>=!%.,]$" then return ("it ends with `%s`"):format(text:sub(-1)) end
end

-- Cmdline completion has to answer synchronously, and the adapter does not.
-- Candidates are therefore fetched into this table before the prompt opens, and
-- a lead that grows a new dot starts a fetch that the *next* `<Tab>` will find.
local candidates, inflight = {}, {}

---@param base string|nil
local function prefetch(base)
  local key = base or ""
  if candidates[key] or inflight[key] then return end

  local session = require("dap").session()
  if session and session.current_frame then
    inflight[key] = true
    require("user.debug.completion").names(base, function(names)
      inflight[key] = nil
      candidates[key] = names
    end)
  elseif base then
    -- Members of an expression are only knowable from a live process.
    candidates[key] = {}
  else
    -- Nothing is running yet, which is when most of these get set.
    candidates[key] = require("user.debug.names").near(vim.api.nvim_get_current_buf())
  end
end

--- Backs the cmdline completion.
---@param lead string
---@return string[]
function M.complete(lead)
  local base = require("user.debug.completion").base(lead)
  local prefix = base and (base .. ".") or ""
  local partial = lead:sub(#prefix + 1)

  prefetch(base)

  local matches = {}
  for _, name in ipairs(candidates[base or ""] or {}) do
    if vim.startswith(name, partial) then table.insert(matches, prefix .. name) end
  end
  table.sort(matches)
  return matches
end

local function completion_function()
  if vim.fn.exists "*UserDebugBreakpointCondition" == 0 then
    vim.cmd [[
      function! UserDebugBreakpointCondition(lead, line, pos) abort
        return luaeval("require('user.debug.condition').complete(_A)", a:lead)
      endfunction
    ]]
  end
  return "customlist,UserDebugBreakpointCondition"
end

-- Which breakpoint the adapter is about to answer for. `setBreakpoints` is sent
-- for every breakpoint in the buffer whenever any of them changes, so the
-- response is only interesting while one is expected.
local pending = nil
local watching = false

local function watch_verification()
  if watching then return end
  watching = true
  require("dap").listeners.after.setBreakpoints.user_debug_condition = function(_, _, response)
    if not pending then return end
    for _, breakpoint in ipairs(response and response.breakpoints or {}) do
      if breakpoint.line == pending and not breakpoint.verified then
        vim.notify(
          ("The debugger would not take that condition: %s"):format(breakpoint.message or "the breakpoint is inactive"),
          vim.log.levels.WARN,
          { title = "Debug" }
        )
      end
    end
    pending = nil
  end
end

---@param condition string
local function apply(condition)
  watch_verification()
  pending = vim.api.nvim_win_get_cursor(0)[1]
  require("dap").set_breakpoint(condition)
  -- Nothing is sent while no session is running, so nothing will answer.
  vim.defer_fn(function() pending = nil end, 2000)
end

--- Ask the debugger what the expression is worth, when there is a debugger to
--- ask. The answer is advisory, not a gate: the frame we are stopped in is
--- often not the scope the breakpoint sits in, so a name that is missing here
--- may well exist there.
---@param condition string
local function report_value(condition)
  local session = require("dap").session()
  local frame = session and session.current_frame
  if not frame then return end

  session:request("evaluate", { expression = condition, frameId = frame.id, context = "watch" }, function(err, resp)
    if err then
      return vim.notify(
        ("The current frame cannot evaluate it: %s\nThe breakpoint is set anyway -- the scope there may differ."):format(
          tostring(err)
        ),
        vim.log.levels.WARN,
        { title = "Debug" }
      )
    end
    if resp and resp.result then
      vim.notify(("%s  →  %s"):format(condition, resp.result), vim.log.levels.INFO, { title = "Debug" })
    end
  end)
end

--- Prompt for a condition and put a breakpoint on this line.
function M.set()
  candidates, inflight = {}, {}
  prefetch(nil)

  vim.ui.input({ prompt = "Breakpoint condition: ", completion = completion_function() }, function(condition)
    if not condition then return end

    local complaint = M.lint(condition)
    if complaint then
      return vim.notify(("Not a usable condition: %s"):format(complaint), vim.log.levels.ERROR, { title = "Debug" })
    end

    apply(condition)
    report_value(condition)
  end)
end

return M
