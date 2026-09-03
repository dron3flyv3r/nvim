local M = {}

local function focus_range()
  local bufnr = vim.api.nvim_get_current_buf()
  local first, last = vim.api.nvim_win_get_cursor(0)[1], vim.api.nvim_win_get_cursor(0)[1]
  local mode = vim.api.nvim_get_mode().mode
  if mode:sub(1, 1) == "v" or mode == "V" or mode == "\22" then
    local anchor, cursor = vim.fn.getpos "v", vim.fn.getpos "."
    first, last = math.min(anchor[2], cursor[2]), math.max(anchor[2], cursor[2])
  end
  return bufnr, first, last
end

local function send(prompt, attach)
  require "claudecode"
  local terminal = require "claudecode.terminal"
  terminal.ensure_visible()
  if attach then
    local bufnr, first, last = focus_range()
    local path = vim.api.nvim_buf_get_name(bufnr)
    if path ~= "" then require("claudecode").send_at_mention(path, first, last, "user.ai_review") end
  end
  terminal.send_to_terminal(prompt)
end

function M.diff()
  send(
    "Review the current uncommitted Git diff. Do not edit files. Report only actionable findings, ordered by severity, with file:line references, reasoning, risks, and missing regression tests. If there are no findings, say so plainly.",
    false
  )
end

function M.selection()
  send(
    "Review the attached code in its repository context. Do not edit files. Report actionable findings ordered by severity with file:line references, reasoning, risks, and missing regression tests. State assumptions where context is incomplete.",
    true
  )
end

function M.investigate()
  send(
    "Investigate how the behavior or bug around the attached code might happen. Do not edit files. Inspect the repository as needed and give ranked hypotheses, concrete execution paths, evidence for or against each, likely source locations, and the smallest tests or observations that would distinguish them. Label assumptions clearly.",
    true
  )
end

return M
