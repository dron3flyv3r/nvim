local M = { id = "unity", name = "Unity", priority = 90 }

function M.detect(ctx)
  local root = require("user.integrations.unity").root(ctx.bufnr)
  return root and vim.fn.fnamemodify(root, ":~") or false
end

function M.actions()
  local actions = require "user.integrations.unity.actions"
  return {
    { id = "unity.play", label = "Enter Play mode", category = "Run", run = actions.play },
    { id = "unity.stop", label = "Stop Play mode", category = "Run", run = actions.stop },
    { id = "unity.restart", label = "Restart Play mode", category = "Run", run = actions.restart },
    { id = "unity.pause", label = "Pause Play mode", category = "Run", run = actions.pause },
    { id = "unity.unpause", label = "Resume Play mode", category = "Run", run = actions.resume },
    { id = "unity.refresh", label = "Refresh assets and recompile", category = "Build", run = actions.refresh },
    {
      id = "unity.test_cursor",
      label = "Run EditMode test under cursor",
      category = "Tests",
      run = actions.test_cursor,
    },
    { id = "unity.test_edit", label = "Choose EditMode test", category = "Tests", run = actions.test_edit },
    { id = "unity.test_play", label = "Choose PlayMode test", category = "Tests", run = actions.test_play },
    { id = "unity.debug", label = "Attach debugger to Unity", category = "Debug", run = actions.attach },
    { id = "unity.errors", label = "Load compiler errors", category = "Problems", run = actions.errors },
    {
      id = "unity.warnings",
      label = "Load compiler errors and warnings",
      category = "Problems",
      run = actions.warnings,
    },
    { id = "unity.log", label = "Follow Unity editor log", category = "Output", run = actions.log },
    { id = "unity.docs", label = "Open Unity docs for symbol", category = "Inspect", run = actions.docs },
    { id = "unity.status", label = "Show Unity integration status", category = "Status", run = actions.status },
    {
      id = "unity.install",
      label = "Install/update Unity editor shim",
      category = "Maintenance",
      run = actions.install,
    },
  }
end

function M.status(ctx)
  local root = require("user.integrations.unity").root(ctx.bufnr)
  return root and { "  Unity root: " .. vim.fn.fnamemodify(root, ":~") } or {}
end

return M
