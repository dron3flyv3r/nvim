-- Completion for the debug REPL, derived from the paused process itself.
--
-- Nothing arrives there by default, for two independent reasons. blink refuses
-- to attach to a `buftype=prompt` buffer, which is what nvim-dap's REPL is (see
-- `plugins/blink.lua`, which re-enables it); and nvim-dap's own omnifunc only
-- works when the adapter advertises `supportsCompletionsRequest`. Microsoft's
-- Unity adapter does not implement that request at all -- `UnityDebugAdapter.dll`
-- ships handlers for evaluate, variables, scopes and eighteen others, and no
-- completions handler -- so there is nobody to ask.
--
-- The candidates are therefore built out of the requests the adapter *does*
-- answer: evaluate whatever sits left of the dot, take the `variablesReference`
-- off the result, and ask for its children. The names come back carrying their
-- current values and runtime types, which is strictly more than a static index
-- could say -- `_feet.` offers `position` alongside the Vector3 it holds right
-- now. The cost is that DAP only reports data members, so methods never appear;
-- for those, the C# language server in the source buffer is still the answer.
local M = {}

local kinds = vim.lsp.protocol.CompletionItemKind

--- Results are only valid for the frame they were fetched in, and a paused
--- process cannot change underneath them -- so they are cached until execution
--- moves.
local cache = {}

local listening = false
local function listen()
  if listening then return end
  listening = true
  local dap = require "dap"
  local function clear() cache = {} end
  dap.listeners.after.event_stopped.user_debug_completion = clear
  dap.listeners.after.event_continued.user_debug_completion = clear
  dap.listeners.after.event_terminated.user_debug_completion = clear
end

---@param variable table a DAP Variable
---@return integer
local function kind_of(variable)
  local hint = (variable.presentationHint or {}).kind
  if hint == "method" then return kinds.Method end
  if hint == "class" then return kinds.Class end
  if hint == "property" then return kinds.Property end
  return variable.variablesReference and variable.variablesReference > 0 and kinds.Field or kinds.Variable
end

---@param variables table[]
---@return table[]
local function items_from(variables)
  local items, seen = {}, {}
  for _, variable in ipairs(variables or {}) do
    -- Adapters put presentation rows among the real members -- "Static members",
    -- "Raw View" -- and those are not expressions anyone can type.
    if variable.name and not variable.name:find "%s" and not seen[variable.name] then
      seen[variable.name] = true
      table.insert(items, {
        label = variable.name,
        kind = kind_of(variable),
        detail = variable.type,
        documentation = variable.value and { kind = "plaintext", value = variable.value } or nil,
      })
    end
  end
  return items
end

--- Members of `expression`, evaluated in the current frame.
local function members(session, frame_id, expression, done)
  session:request("evaluate", { expression = expression, frameId = frame_id, context = "repl" }, function(err, resp)
    local reference = not err and resp and resp.variablesReference or 0
    if reference == 0 then return done {} end
    session:request(
      "variables",
      { variablesReference = reference },
      function(_, variables) done(items_from(variables and variables.variables)) end
    )
  end)
end

--- Everything nameable in the current frame: locals, parameters, `this`, statics.
local function in_scope(session, frame_id, done)
  session:request("scopes", { frameId = frame_id }, function(err, resp)
    local scopes = not err and resp and resp.scopes or {}
    local pending, collected = #scopes, {}
    if pending == 0 then return done {} end

    for _, scope in ipairs(scopes) do
      session:request("variables", { variablesReference = scope.variablesReference }, function(_, variables)
        vim.list_extend(collected, variables and variables.variables or {})
        pending = pending - 1
        if pending == 0 then done(items_from(collected)) end
      end)
    end
  end)
end

--- The adapter's own answer, when it has one. codelldb does; the Unity adapter
--- does not, which is the whole reason for the code above.
local function native(session, frame_id, text, done)
  session:request("completions", { frameId = frame_id, text = text, column = #text + 1 }, function(err, resp)
    if err or not resp then return done {} end
    local items = {}
    for _, target in ipairs(resp.targets or {}) do
      table.insert(items, {
        label = target.label,
        insertText = target.text or target.label,
        kind = target.type == "method" and kinds.Method or kinds.Variable,
        detail = target.detail,
      })
    end
    done(items)
  end)
end

--- The expression whose members are being asked for: everything left of the dot
--- the cursor sits after. The chain stops at anything that cannot be part of
--- one, so `Mathf.Sqrt(x.y` asks about `x` and not about the whole line.
---@param text string the REPL line with the prompt stripped, up to the cursor
---@return string|nil base nil when the cursor is on a bare name
function M.base(text)
  local chain = text:match "[%w_%.%[%]]*$" or ""
  return chain:match "^(.+)%.[%w_]*$"
end

--- The same candidates as plain names, for the conditional-breakpoint prompt:
--- it needs the frame's answer in the shape cmdline completion expects.
---@param base string|nil the expression whose members are wanted, or nil for the frame
---@param done fun(names: string[])
function M.names(base, done)
  local session = require("dap").session()
  local frame = session and session.current_frame
  if not frame then return done {} end
  listen()

  local function to_names(items)
    done(vim.tbl_map(function(item) return item.label end, items))
  end
  if base then
    members(session, frame.id, base, to_names)
  else
    in_scope(session, frame.id, to_names)
  end
end

local source = {}
source.__index = source

function M.new() return setmetatable({}, source) end

function source:enabled()
  local ok, dap = pcall(require, "dap")
  return ok and vim.bo.filetype == "dap-repl" and dap.session() ~= nil
end

function source:get_trigger_characters() return { "." } end

function source:get_completions(context, callback)
  local session = require("dap").session()
  local frame = session and session.current_frame
  local cancelled = false

  local function finish(items)
    if cancelled then return end
    callback { is_incomplete_forward = false, is_incomplete_backward = false, items = items, context = context }
  end

  if not frame then
    -- Attached but still running: there is no frame, so the adapter cannot
    -- evaluate anything. Rather than going silent -- which reads as "completion
    -- is broken" -- the names from the file being debugged are offered, labelled
    -- so it is clear they carry no value yet.
    local names = require "user.debug.names"
    local source_buffer = names.source_buffer()
    finish(
      vim.tbl_map(
        function(name) return { label = name, kind = kinds.Text, detail = "source text -- not stopped" } end,
        source_buffer and names.near(source_buffer) or {}
      )
    )
    return function() end
  end
  listen()

  -- The prompt prefix is part of the buffer line, and is not part of the
  -- expression the adapter is being asked about.
  local buf = vim.api.nvim_get_current_buf()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local text = line:sub(#vim.fn.prompt_getprompt(buf) + 1, col)

  local base = M.base(text)

  if (session.capabilities or {}).supportsCompletionsRequest then
    -- Not cached: the adapter is answering about the whole line, so the answer
    -- changes with every keystroke.
    native(session, frame.id, text, finish)
    return function() cancelled = true end
  end

  -- The derived answers depend only on the frame and the expression left of the
  -- dot, both of which are fixed until execution moves.
  local key = ("%s\0%s"):format(tostring(frame.id), base or "")
  if cache[key] then
    finish(cache[key])
    return function() end
  end

  local function cache_and_finish(items)
    cache[key] = items
    finish(items)
  end

  if base then
    members(session, frame.id, base, cache_and_finish)
  else
    in_scope(session, frame.id, cache_and_finish)
  end

  return function() cancelled = true end
end

return M
