-- Unity's editor log, which is where the compiler output that Neovim cannot see
-- ends up.
--
-- WHY THIS IS NEEDED WHEN THERE IS ALREADY A LANGUAGE SERVER. `roslyn_ls` and
-- Unity compile the same code with the same compiler, but not with the same
-- inputs. Unity knows about things the csproj files do not describe:
--
--   * assembly definition boundaries, so `Foo.cs` in an asmdef with no
--     reference to `Bar`'s asmdef is an error Unity reports and Roslyn does not
--     (Roslyn is reading a csproj that was generated *before* you added the
--     reference);
--   * IL post-processors and source generators Unity runs itself;
--   * anything at all, when the csproj files are stale -- which they are from
--     the moment you add a file until Unity next syncs.
--
-- So Unity's own errors are the ground truth, and they are printed to a log
-- file rather than anywhere Neovim would notice. `M.errors()` scrapes them into
-- the quickfix list, which puts them on the same keys as every other build
-- failure in this config (`æq` / `øq`).
--
-- WHY THE LAST N LINES AND NOT A PROPER PARSE. The log is append-only for the
-- whole editor session and can reach hundreds of megabytes; it interleaves
-- compiler output with asset imports, shader compiles and every `Debug.Log` the
-- game has ever printed. There is no reliable "start of the last compile"
-- marker across Unity versions -- the `-----CompilerOutput:` banners come and
-- go. Reading the tail and de-duplicating gets the errors that matter, and
-- being occasionally one compile stale is a much better failure than parsing
-- the whole file on every keypress.

local M = {}

--- How far apart two diagnostic lines can be and still count as one compile.
---
--- Unity prints a compile's errors as a run of adjacent lines, usually two or
--- three times over (once per assembly attempt, with a
--- `*** Tundra build failed` between the repeats). Between one compile and the
--- next there are thousands of lines of asset imports, licensing chatter and
--- shader compiles. A couple of hundred lines is comfortably wider than any
--- within-compile interruption and far narrower than the gap between compiles.
local BLOCK_GAP = 400

--- `Assets/Foo/Bar.cs(12,34): error CS0103: message`
---
--- Unity prints the path relative to the project root, uses `(line,col)`, and
--- says `error` or `warning` followed by the Roslyn code. Anchored to the start
--- of the line so that a path quoted inside a message is not mistaken for one.
local PATTERN = "^([%w_%-%./ ]+%.cs)%((%d+),(%d+)%):%s+(%a+)%s+(%u+%d+):%s*(.*)$"

--- The diagnostics from the *last* compile in the log.
---
--- WHY THE WHOLE FILE IS STREAMED. The first version of this read the last few
--- thousand lines, on the theory that the newest compile is at the end. It is
--- not. This machine's editor log is 635,000 lines and the most recent
--- compiler errors sit at line 619,573 -- fifteen thousand lines of asset
--- imports were appended after them, so a 4,000-line tail found nothing at all
--- while the project was visibly failing to compile.
---
--- There is no reliable banner to anchor on instead: the `-----CompilerOutput:`
--- blocks that older Unity versions printed do not appear in a Unity 6 log at
--- all, and anything else worth matching changes between versions. What does
--- hold across versions is the *shape*: a compile's diagnostics are adjacent to
--- each other and nothing else is. So stream the file once, keep the last run
--- of diagnostics, and let `BLOCK_GAP` decide where a run ends.
---
--- One pass, one line held at a time, and the state is a list bounded by the
--- size of one compile's output rather than by the size of the log. It is also
--- pure Lua on purpose: `grep` on this machine is `ugrep`, and `tail` and
--- `grep` flag behaviour is not something a config should be betting on.
---@param root string
---@param include_warnings? boolean
---@return table[] items Quickfix items, in the order Unity printed them.
function M.diagnostics(root, include_warnings)
  local log = require("user.integrations.unity").log_file()
  local file = io.open(log, "r")
  if not file then return {} end

  local block, seen, previous = {}, {}, nil
  local number = 0
  for line in file:lines() do
    number = number + 1
    local path, lnum, col, severity, code, message = line:match(PATTERN)
    if path and (severity == "error" or severity == "warning") then
      if previous and number - previous > BLOCK_GAP then
        -- A new compile. Everything collected so far is history.
        block, seen = {}, {}
      end
      previous = number

      -- Unity prints each diagnostic several times per compile; the file, the
      -- position and the code together identify it.
      local key = ("%s:%s:%s:%s"):format(path, lnum, col, code)
      if not seen[key] then
        seen[key] = true
        table.insert(block, {
          -- The path is relative to the project root, and a quickfix entry is
          -- resolved against the cwd -- which is not necessarily the same
          -- place. Absolute, so the entry is jumpable from anywhere.
          filename = vim.startswith(path, "/") and path or (root .. "/" .. path),
          lnum = tonumber(lnum),
          col = tonumber(col),
          type = severity == "error" and "E" or "W",
          text = ("%s: %s"):format(code, message),
          severity = severity,
        })
      end
    end
  end
  file:close()

  if include_warnings then return block end
  return vim.tbl_filter(function(item) return item.severity == "error" end, block)
end

--- Load Unity's compiler diagnostics into the quickfix list.
---@param include_warnings? boolean
function M.errors(include_warnings)
  local root = require("user.integrations.unity").require_root()
  if not root then return end

  local kind = include_warnings and "diagnostic" or "error"
  local items = M.diagnostics(root, include_warnings)

  if vim.tbl_isempty(items) then
    -- Empty means Unity's last compile was clean, not that the scrape failed --
    -- worth saying, because it is the answer you are usually hoping for.
    vim.notify(("Unity's last compile had no %ss"):format(kind), vim.log.levels.INFO, { title = "Unity" })
    vim.fn.setqflist({}, " ", { title = "Unity compile", items = {} })
    return
  end

  vim.fn.setqflist({}, " ", { title = "Unity compile", items = items })
  vim.notify(
    ("%d Unity %s%s in the quickfix list (æq / øq)"):format(#items, kind, #items == 1 and "" or "s"),
    vim.log.levels.WARN,
    { title = "Unity" }
  )
  vim.cmd.cfirst()
end

--- Follow the editor log in a terminal split.
---
--- A terminal rather than a buffer with `autoread`: the log is appended to
--- constantly and a reloading buffer fights the cursor. This is the same
--- reasoning as `overseer`'s output pane in `plugins/tasks.lua`.
function M.tail()
  local log = require("user.integrations.unity").log_file()
  if vim.fn.filereadable(log) ~= 1 then
    vim.notify(("No editor log at %s"):format(log), vim.log.levels.WARN, { title = "Unity" })
    return
  end
  vim.cmd "botright 15split"
  vim.cmd.terminal(("tail -n 200 -f %s"):format(vim.fn.fnameescape(log)))
  vim.cmd "startinsert"
end

return M
