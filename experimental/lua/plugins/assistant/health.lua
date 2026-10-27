local M = {}

function M.check()
  local health = vim.health
  health.start "assistant"

  if pcall(require, "claudecode") then
    health.ok "claudecode.nvim: the server Claude instances share, for the selection and diff accept/deny"
    health.info "the websocket server is :checkhealth claudecode; the terminals are plugins.assistant.agents"
  else
    health.error "claudecode.nvim is not installed -- <Leader>a does nothing"
  end

  for _, agent in ipairs(require("plugins.assistant.agents").AGENTS) do
    if vim.fn.executable(agent.cmd[1]) == 1 then
      health.ok(("%s: %s"):format(agent.name, vim.fn.exepath(agent.cmd[1])))
    else
      health.info(("%s: %s is not on PATH, so <Leader>aa does not offer it"):format(agent.name, agent.cmd[1]))
    end
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
