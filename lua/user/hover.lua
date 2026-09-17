-- `K`, with the three things the built-in hover gets wrong for this config.
--
-- 1. Size. `vim.lsp.util.make_floating_popup_options` clamps the float's height
--    to the room between the cursor and the edge of the window, so the
--    `max_height` asked for below is only ever honoured with the cursor near a
--    screen edge. Mid-screen a 31-line doc gets 22 lines and the rest is simply
--    off the bottom, which reads as "the docs are missing" rather than "the
--    docs are scrolled". `refit` re-anchors the window to the editor once the
--    content is in, which is the only way out: the clamp is unconditional.
--
-- 2. Markup. Roslyn emits HTML entities for indentation and CommonMark escapes
--    for ordinary punctuation. Neither survives the trip: the markdown parser
--    does not decode entities, and nothing conceals `backslash_escape`. So
--    `&nbsp;&nbsp;The distance travelled\.` is what lands on screen verbatim.
--    `sanitize` undoes both, outside fenced code where the escapes are real.
--
-- 3. Constructors. `new Foo()` resolves to the *constructor* symbol, and when a
--    class declares no constructor the implicit one carries no doc comment --
--    so the class-level `<summary>` never appears, even though hovering `Foo`
--    itself shows it in full. Roslyn does not fall back to the containing type
--    the way Rider does. `with_type_fallback` does it client-side, and only
--    when the server answered with a bare signature and no prose at all.
local M = {}

-- Punctuation that means something to the markdown parser: unescaping these
-- would turn documentation text into emphasis, links or code spans.
local STRUCTURAL = { ["`"] = true, ["*"] = true, ["_"] = true, ["["] = true, ["]"] = true, ["|"] = true, ["~"] = true }

-- Structural only in the first column, where they start a list, heading or
-- quote. Mid-line they are just punctuation, and `widget\-shaped` is the common
-- case worth fixing.
local LEADING = { ["-"] = true, ["+"] = true, ["#"] = true, [">"] = true }

local ENTITIES = {
  nbsp = " ",
  lt = "<",
  gt = ">",
  amp = "&",
  quot = '"',
  apos = "'",
}

--- Undo the server-side markup that Neovim renders literally.
---@param value string markdown as the server sent it
---@return string
function M.sanitize(value)
  local lines = vim.split(value, "\n", { plain = true })
  local fenced = false

  for i, line in ipairs(lines) do
    if line:match "^%s*```" then
      fenced = not fenced
    elseif not fenced then
      -- `&nbsp;` is Roslyn's indentation for `<returns>` and `<param>` bodies.
      line = line:gsub("&(#?%w+);", function(name)
        local entity = ENTITIES[name:lower()]
        if entity then return entity end
        local code = name:match "^#(%d+)$"
        return code and vim.fn.nr2char(tonumber(code)) or nil
      end)

      local leading = true
      line = line:gsub("()\\(%p)", function(pos, char)
        -- Only the first escape on the line can be in leading position, and
        -- only if nothing but whitespace precedes it.
        local prefix = line:sub(1, pos - 1)
        leading = prefix:match "^%s*$" ~= nil
        if STRUCTURAL[char] or char == "\\" then return nil end
        if leading and LEADING[char] then return nil end
        return char
      end)

      lines[i] = line
    end
  end

  return table.concat(lines, "\n")
end

--- Everything left once fenced code blocks are removed. Empty means the server
--- gave us a signature and nothing else, which is the case worth a second look.
---@param value string
---@return boolean
function M.has_prose(value)
  local stripped = value:gsub("```[^\n]*\n.-\n```", ""):gsub("&nbsp;", " ")
  return stripped:match "%S" ~= nil
end

--- Ask the server for the type behind a bare constructor signature.
---
--- `textDocument/definition` on `new Foo()` lands on the class declaration --
--- verified against roslyn_ls for both same-file and cross-file types, the
--- latter without the defining buffer ever being loaded in Neovim. A second
--- hover there returns the `<summary>` the constructor lacked.
---@param client vim.lsp.Client
---@param bufnr integer
---@param params table the position params of the original hover
---@param callback fun(value: string?)
local function with_type_fallback(client, bufnr, params, callback)
  client:request("textDocument/definition", params, function(_, locations)
    local location = locations and (locations[1] or locations)
    local uri = location and (location.uri or location.targetUri)
    local range = location and (location.range or location.targetSelectionRange)
    if not uri or not range then return callback(nil) end

    -- Landing back on the token we started from means the definition *is* the
    -- symbol we already hovered; a second request would return the same thing.
    if uri == params.textDocument.uri and range.start.line == params.position.line then
      if range.start.character == params.position.character then return callback(nil) end
    end

    client:request("textDocument/hover", {
      textDocument = { uri = uri },
      position = range.start,
    }, function(_, result)
      local value = result and result.contents and result.contents.value
      callback(value and M.has_prose(value) and value or nil)
    end, bufnr)
  end, bufnr)
end

--- The float geometry this config wants, before Neovim clamps it.
---@return integer max_width, integer max_height
local function dimensions()
  local max_width = math.min(math.max(1, vim.o.columns - 8), math.max(50, math.floor(vim.o.columns * 0.82)))
  local max_height = math.min(math.max(1, vim.o.lines - 6), math.max(10, math.floor(vim.o.lines * 0.75)))
  return max_width, max_height
end

--- Options shared with any other plugin that opens a hover-shaped float, so a
--- Rust hover and a C# hover look like the same window.
---@return table
function M.float_opts()
  local max_width, max_height = dimensions()
  return {
    border = "rounded",
    title = " Documentation ",
    title_pos = "center",
    max_width = max_width,
    max_height = max_height,
    wrap = true,
    focus = true,
  }
end

--- Size a hover float to its content, re-anchoring to the editor if growing is
--- what it takes.
---
--- Cursor-relative floats cannot be taller than the gap between the cursor and
--- the window edge, so a doc that does not fit is silently cut rather than
--- scrolled into view. Editor-relative floats may overlap the cursor line,
--- which is the right trade when the alternative is not seeing the text.
---
--- Safe to call more than once: render-markdown decorates the buffer on a
--- debounce, and its virtual lines change how tall the text really is. This
--- converges rather than ratcheting, so a second pass after it has drawn
--- settles on the right size in both directions.
---@param win integer? window id of the float
function M.refit(win)
  if not win or not vim.api.nvim_win_is_valid(win) then return end

  local buf = vim.api.nvim_win_get_buf(win)
  local config = vim.api.nvim_win_get_config(win)
  if config.relative == "" then return end

  local max_width, max_height = dimensions()

  -- Width first: how many rows the text needs depends on where it wraps. Only
  -- ever widen -- narrowing would reflow text that already fits.
  local width = 0
  for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  width = math.max(math.min(width, max_width), config.width)
  if width ~= config.width then vim.api.nvim_win_set_config(win, { width = width }) end

  -- Borders cost a row top and bottom, and the cmdline owns the last rows.
  local border = 2
  local available = vim.o.lines - vim.o.cmdheight - 1
  local needed = vim.api.nvim_win_text_height(win, {}).all
  local height = math.max(1, math.min(needed, max_height, available - border))
  if height == config.height then return end

  -- Shrinking only ever reclaims blank rows, so the window can stay where it
  -- is; growing is the case that may not fit beside the cursor any more.
  if height < config.height then
    vim.api.nvim_win_set_config(win, { height = height })
    return
  end

  local screen_row, screen_col = vim.fn.screenrow(), vim.fn.screencol()

  -- `screenrow()` is 1-based, so it doubles as the 0-based row *below* the
  -- cursor: start there, and slide up only as far as staying on screen needs.
  local row = screen_row
  if row + height + border > available then row = math.max(0, available - height - border) end
  local col = math.min(screen_col - 1, math.max(0, vim.o.columns - width - border))

  vim.api.nvim_win_set_config(win, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
  })
end

--- Find an open float by the `focus_id` `open_floating_preview` stamped on it.
---@param focus_id string
---@return integer? win
function M.find_float(focus_id)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local ok, value = pcall(vim.api.nvim_win_get_var, win, focus_id)
    if ok and value then return win end
  end
end

--- Refit now, then again once render-markdown's debounced pass has drawn.
---
--- Its virtual lines are part of the rendered height, so the size settled on
--- before it runs is measured against text that is about to change shape.
---@param win integer? window id of the float
function M.settle(win)
  M.refit(win)
  for _, delay in ipairs { 150, 450 } do
    vim.defer_fn(function() M.refit(win) end, delay)
  end
end

--- Settle a float opened by someone else, once it exists.
---@param focus_id string
function M.refit_later(focus_id)
  vim.defer_fn(function() M.settle(M.find_float(focus_id)) end, 120)
end

local FOCUS_ID = "textDocument/hover"

--- Send the collected hover markdown to a scratch buffer in a split.
---
--- The escape hatch for docs that are long enough that scrolling a float is the
--- wrong shape of interaction: a normal window searches, folds and yanks.
---@param lines string[]
local function open_in_split(lines)
  vim.cmd "new"
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  vim.wo[0].conceallevel = 2
  vim.wo[0].wrap = true
  vim.wo[0].linebreak = true
  vim.keymap.set("n", "q", "<Cmd>close<CR>", { buffer = buf, nowait = true, desc = "Close documentation" })
end

--- Render the assembled markdown and size the window around it.
---@param contents string[]
local function show(contents)
  local opts = M.float_opts()
  opts.focus_id = FOCUS_ID

  local buf, win = vim.lsp.util.open_floating_preview(contents, "markdown", opts)
  M.settle(win)

  vim.keymap.set("n", "<Esc>", "<Cmd>close<CR>", { buffer = buf, nowait = true, desc = "Close documentation" })
  vim.keymap.set("n", "<CR>", function()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    vim.api.nvim_win_close(win, true)
    open_in_split(lines)
  end, { buffer = buf, nowait = true, desc = "Open documentation in a split" })

  -- Once everything has settled, say so when the doc is genuinely longer than a
  -- float should be: scrolling is the thing worth avoiding, and the way out is
  -- only useful if it is visible at the moment it is needed.
  vim.defer_fn(function()
    if not vim.api.nvim_win_is_valid(win) then return end
    local config = vim.api.nvim_win_get_config(win)
    if vim.api.nvim_win_text_height(win, {}).all <= config.height then return end
    pcall(vim.api.nvim_win_set_config, win, { title = " Documentation  ·  <CR> for split ", title_pos = "center" })
  end, 500)

  return buf, win
end

--- Documentation for the symbol under the cursor.
function M.open()
  local bufnr = vim.api.nvim_get_current_buf()
  local winnr = vim.api.nvim_get_current_win()

  -- Second `K` focuses the float rather than opening another one, which is how
  -- the cheatsheet advertises it.
  local existing = M.find_float(FOCUS_ID)
  if existing and vim.fn.pumvisible() == 0 then
    vim.api.nvim_set_current_win(existing)
    return
  end

  -- rustaceanvim's hover carries the code actions with it, which is worth more
  -- than anything below. Dispatching here rather than from a second `K` mapping
  -- keeps one owner for the key: two mappings share one slot and the loser
  -- takes every language with it.
  if not vim.tbl_isempty(vim.lsp.get_clients { bufnr = bufnr, name = "rust-analyzer" }) then
    vim.cmd "RustLsp hover actions"
    M.refit_later "rust-analyzer-hover-actions"
    return
  end

  local function position_params(client) return vim.lsp.util.make_position_params(winnr, client.offset_encoding) end

  vim.lsp.buf_request_all(bufnr, "textDocument/hover", position_params, function(results)
    if not vim.api.nvim_buf_is_valid(bufnr) then return end

    -- Collect what came back, keeping the client around: the fallback needs to
    -- go back to the same server that gave us the bare signature.
    local answers = {}
    for client_id, response in pairs(results) do
      local value = response.result and response.result.contents and response.result.contents.value
      -- `contents` may also be a bare string or a list; normalise through the
      -- upstream converter and only take the shortcut when it is MarkupContent.
      if not value and response.result and response.result.contents then
        value = table.concat(vim.lsp.util.convert_input_to_markdown_lines(response.result.contents), "\n")
      end
      if value and value:match "%S" then
        local client = vim.lsp.get_client_by_id(client_id)
        if client then table.insert(answers, { client = client, value = value }) end
      end
    end

    if vim.tbl_isempty(answers) then
      vim.notify("No information available", vim.log.levels.INFO)
      return
    end

    local pending = 0
    local function render()
      local contents = {}
      for _, answer in ipairs(answers) do
        if #answers > 1 then table.insert(contents, ("# %s"):format(answer.client.name)) end
        vim.list_extend(contents, vim.split(M.sanitize(answer.value), "\n", { plain = true }))
        table.insert(contents, "---")
      end
      contents[#contents] = nil
      show(contents)
    end

    for _, answer in ipairs(answers) do
      if not M.has_prose(answer.value) then
        pending = pending + 1
        with_type_fallback(answer.client, bufnr, position_params(answer.client), function(value)
          -- Keep the signature the server gave us and append what the type
          -- knows, so `new Foo()` still says which overload it resolved to.
          if value then answer.value = answer.value:gsub("%s*$", "") .. "\n\n---\n\n" .. value end
          pending = pending - 1
          if pending == 0 then render() end
        end)
      end
    end

    if pending == 0 then render() end
  end)
end

return M
