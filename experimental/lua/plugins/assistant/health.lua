local M = {}

function M.check()
  local health = vim.health
  health.start "assistant"

  if pcall(require, "claudecode") then
    health.ok "claudecode.nvim: the agent terminal, @ mentions and diff accept/deny"
    health.info "the CLI, the websocket server and the terminal provider are :checkhealth claudecode"
  else
    health.error "claudecode.nvim is not installed -- <Leader>a does nothing"
  end

  if pcall(require, "snacks") then
    health.ok "snacks.nvim: the terminal the agent runs in"
  else
    health.error "snacks.nvim is not installed -- terminal.provider is set to `snacks`"
  end

  -- The one reference between this layer and the git one, and a `pcall`, so it
  -- fails by going quiet.
  local ok, review = pcall(require, "plugins.git.review")
  if not ok then
    health.info "no git layer: nothing warns when Claude edits a file a review is holding"
  elseif type(review.held) == "function" then
    health.ok "the review guard is wired: plugins.git.review.held answers"
  else
    health.error "plugins.git.review.held is gone -- Claude will edit files a review holds with no warning"
  end
end

return M
