local M = {}

local ENTITIES = { lt = "<", gt = ">", amp = "&", quot = '"', apos = "'", nbsp = " " }

---@param text string
---@return string
local function unescape(text)
  return (
    text:gsub("&(#?)([xX]?)(%w+);", function(hash, hex, name)
      if hash == "" then return ENTITIES[name] end
      local code = tonumber(name, hex ~= "" and 16 or 10)
      return code and vim.fn.nr2char(code) or nil
    end)
  )
end

---@param html string
---@return string
local function strip(html) return unescape((html:gsub("<[^>]*>", ""))) end

local INLINE = {
  { "<code[^>]*>(.-)</code>", "`%1`" },
  { "<strong[^>]*>(.-)</strong>", "**%1**" },
  { "<b>(.-)</b>", "**%1**" },
  { "<em[^>]*>(.-)</em>", "*%1*" },
  { "<i>(.-)</i>", "*%1*" },
  { '<a[^>]-href="([^"]*)"[^>]*>(.-)</a>', "[%2](%1)" },
}

local BLOCK = {
  { "<h[12][^>]*>", "\n\n## " },
  { "<h[3-6][^>]*>", "\n\n### " },
  { "</h%d>", "\n\n" },
  { "<li[^>]*>", "\n- " },
  { "</?p[^>]*>", "\n\n" },
  { "</?[uo]l[^>]*>", "\n\n" },
  { "<br%s*/?>", "\n" },
  { "<tr[^>]*>", "\n" },
  { "</t[dh]>", " | " },
}

-- Code blocks are lifted out first: everything else collapses whitespace, and
-- the indentation inside a <pre> is the code.
---@param html string
---@param lang? string
---@return string[]
function M.to_markdown(html, lang)
  local blocks = {}
  html = html:gsub("<pre[^>]*>(.-)</pre>", function(code)
    blocks[#blocks + 1] = ("```%s\n%s\n```"):format(lang or "", vim.trim(strip(code)))
    return ("\n\n\1%d\1\n\n"):format(#blocks)
  end)
  html = html:gsub("%s+", " ")
  for _, rule in ipairs(INLINE) do
    html = html:gsub(rule[1], rule[2])
  end
  for _, rule in ipairs(BLOCK) do
    html = html:gsub(rule[1], rule[2])
  end
  local text = strip(html):gsub("\1(%d+)\1", function(index) return blocks[tonumber(index)] end)

  local lines, fenced = {}, false
  for line in vim.gsplit(text, "\n", { plain = true }) do
    if line:match "^%s*```" then
      fenced = not fenced
      lines[#lines + 1] = vim.trim(line)
    elseif fenced then
      lines[#lines + 1] = line
    else
      line = vim.trim(line):gsub("^%- +", "- ")
      if line ~= "" or (lines[#lines] and lines[#lines] ~= "") then lines[#lines + 1] = line end
    end
  end
  if lines[#lines] == "" then lines[#lines] = nil end
  return lines
end

return M
