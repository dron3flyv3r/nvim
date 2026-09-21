local M = {}

---@param args string[]
---@param cwd string
---@return string?
local function git(args, cwd)
  local cmd = { "git" }
  vim.list_extend(cmd, args)
  local res = vim.system(cmd, { cwd = cwd, text = true }):wait()
  if res.code ~= 0 then return nil end
  return vim.trim(res.stdout or "")
end

function M.check()
  local health = vim.health
  health.start "git"

  local version = vim.fn.executable "git" == 1 and git({ "--version" }, vim.fn.getcwd()) or nil
  if version then
    health.ok(version)
  else
    health.error "git is not on PATH"
  end

  for module, what in pairs {
    gitsigns = "signs, hunks and blame",
    diffview = "the review and the merge tool",
    neogit = "staging, committing and branches",
  } do
    -- Requiring it loads it: lazy's loader answers a require for a plugin
    -- module, so this reports installation rather than what is already up.
    if pcall(require, module) then
      health.ok(("%s: %s"):format(module, what))
    else
      health.error(("%s is not installed -- %s will not work"):format(module, what))
    end
  end

  -- `inline:` and `linematch` are what make a hunk readable line for line. They
  -- are on by default on this nightly, so this is a check that nothing local
  -- has replaced `diffopt` wholesale.
  local diffopt = vim.o.diffopt
  for _, token in ipairs { "internal", "linematch:", "inline:" } do
    if diffopt:find(token, 1, true) then
      health.ok(("diffopt has %s"):format(token))
    else
      health.warn(("diffopt is missing %s"):format(token), { "diffs will be harder to read line for line" })
    end
  end

  local root = git({ "rev-parse", "--show-toplevel" }, vim.fn.getcwd())
  if not root then return health.info "not inside a git repository" end
  health.info(("repository: %s"):format(vim.fn.fnamemodify(root, ":~")))

  local unmerged = git({ "diff", "--name-only", "--diff-filter=U" }, root)
  if unmerged and unmerged ~= "" then
    local files = vim.split(unmerged, "\n", { trimempty = true })
    health.warn(("%d unmerged file%s"):format(#files, #files == 1 and "" or "s"), { "resolve them with <Leader>gd" })
  end

  -- `merge.conflictStyle` decides whether a conflict region carries its base
  -- section, which is the difference between <Leader>cb taking BASE and only
  -- being able to show it.
  local style = git({ "config", "--get", "merge.conflictStyle" }, root) or "merge"
  if style == "merge" then
    health.info "merge.conflictStyle is `merge`: conflicts carry no BASE section, so <Leader>cb shows stage 1 instead"
  else
    health.ok(("merge.conflictStyle is `%s`: <Leader>cb can take BASE directly"):format(style))
  end
end

return M
