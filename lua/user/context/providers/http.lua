local M = { id = "http", name = "HTTP", priority = 35 }

function M.detect(ctx)
  if ctx.filetype == "http" or ctx.filetype == "rest" then return "HTTP request buffer" end
  return false
end

local function kulala(fn)
  return function() require("kulala")[fn]() end
end

function M.actions()
  return {
    { id = "http.run", label = "Run request at cursor", category = "HTTP", run = kulala "run" },
    { id = "http.run_all", label = "Run all requests", category = "HTTP", run = kulala "run_all" },
    { id = "http.environment", label = "Choose HTTP environment", category = "HTTP", run = kulala "set_selected_env" },
    { id = "http.response", label = "Show last HTTP response", category = "HTTP", run = kulala "open" },
  }
end

return M
