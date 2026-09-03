local M = {}

local function root(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  local start = name ~= "" and vim.fs.dirname(name) or vim.fn.getcwd()
  local dotgit = vim.fs.find(".git", { path = start, upward = true })[1]
  return dotgit and vim.fs.dirname(dotgit) or vim.fn.getcwd()
end

local function directory(bufnr)
  local project = root(bufnr)
  local label = vim.fn.fnamemodify(project, ":t"):gsub("[^%w._-]", "-")
  return vim.fs.joinpath(vim.fn.stdpath "data", "project-notes", label .. "-" .. vim.fn.sha256(project):sub(1, 10))
end

local function selected()
  local mode = vim.api.nvim_get_mode().mode
  if mode:sub(1, 1) == "v" or mode == "V" or mode == "\22" then
    local anchor, cursor = vim.fn.getpos "v", vim.fn.getpos "."
    local lines = vim.fn.getregion(anchor, cursor, { type = mode })
    return table.concat(lines, "\n"), math.min(anchor[2], cursor[2]), math.max(anchor[2], cursor[2])
  end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  return vim.api.nvim_get_current_line(), line, line
end

local function slug(value) return value:lower():gsub("[^%w]+", "-"):gsub("^-+", ""):gsub("-+$", "") end

function M.create()
  local bufnr = vim.api.nvim_get_current_buf()
  local text, first, last = selected()
  local source = vim.api.nvim_buf_get_name(bufnr)
  vim.ui.input({ prompt = "Note title: " }, function(title)
    title = title and vim.trim(title) or ""
    if title == "" then return end
    local dir = directory(bufnr)
    vim.fn.mkdir(dir, "p")
    local path = vim.fs.joinpath(dir, os.date "%Y-%m-%d-" .. slug(title) .. ".md")
    local uri = source ~= "" and vim.uri_from_fname(source) .. "#L" .. first .. "-L" .. last or "[unsaved buffer]"
    local fence = "```"
    vim.cmd.edit(vim.fn.fnameescape(path))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, {
      "# " .. title,
      "",
      "- Created: " .. os.date "%Y-%m-%d %H:%M",
      "- Project: `" .. root(bufnr) .. "`",
      "- Source: [" .. (source ~= "" and vim.fn.fnamemodify(source, ":~:.") or "unsaved buffer") .. "](" .. uri .. ")",
      "",
      "## Context",
      "",
      fence .. vim.bo[bufnr].filetype,
      text,
      fence,
      "",
      "## Notes",
      "",
    })
    vim.cmd.write()
    vim.cmd "normal! G"
  end)
end

function M.open()
  local dir = directory(vim.api.nvim_get_current_buf())
  vim.fn.mkdir(dir, "p")
  require("snacks").picker.files { cwd = dir, title = "Project notes" }
end

function M.search()
  local dir = directory(vim.api.nvim_get_current_buf())
  vim.fn.mkdir(dir, "p")
  require("snacks").picker.grep { cwd = dir, title = "Search project notes" }
end

return M
