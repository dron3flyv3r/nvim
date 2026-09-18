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
    {
      id = "unity.android_debug",
      label = "Attach debugger to Android device",
      category = "Debug",
      run = actions.android_attach,
    },
    {
      id = "unity.android_status",
      label = "Show Android device and player status",
      category = "Status",
      run = actions.android_status,
    },
    { id = "unity.errors", label = "Open compile errors", category = "Problems", run = actions.errors },
    {
      id = "unity.warnings",
      label = "Open compile errors and warnings",
      category = "Problems",
      run = actions.warnings,
    },
    { id = "unity.log", label = "Follow Unity editor log", category = "Output", run = actions.log },
    {
      id = "unity.android_log",
      label = "Follow / stop Android device log",
      category = "Output",
      run = actions.android_log,
    },
    {
      id = "unity.android_frames",
      label = "Open stack frames from the device log",
      category = "Problems",
      run = actions.android_frames,
    },
    { id = "unity.docs", label = "Open Unity docs for symbol", category = "Inspect", run = actions.docs },
    { id = "unity.status", label = "Show Unity integration status", category = "Status", run = actions.status },
    {
      id = "unity.install",
      label = "Install/update Unity editor shim",
      category = "Maintenance",
      run = actions.install,
    },
    {
      id = "unity.bridge_install",
      label = "Install/update Unity status bridge",
      category = "Maintenance",
      run = actions.bridge_install,
    },
    {
      id = "unity.bridge_remove",
      label = "Remove Unity status bridge",
      category = "Maintenance",
      run = actions.bridge_remove,
    },
  }
end

function M.status(ctx)
  local root = require("user.integrations.unity").root(ctx.bufnr)
  if not root then return {} end

  local lines = { "  Unity root: " .. vim.fn.fnamemodify(root, ":~") }

  local state = require("user.integrations.unity.state").get()
  if state.root ~= root then
    table.insert(lines, "  Editor: no status bridge installed (:UnityCompanion)")
    return lines
  end

  table.insert(lines, "  Editor: " .. (state.running and state.state or "not running"))
  if state.errors > 0 or state.warnings > 0 then
    table.insert(lines, ("  Last compile: %d error(s), %d warning(s)"):format(state.errors, state.warnings))
  end
  if state.stale then table.insert(lines, "  Bridge is out of date -- re-run :UnityCompanion") end
  return lines
end

return M
