local roslyn = require "lang.csharp.roslyn"

---@type plugins.analysis.Language
return {
  filetypes = { "cs" },
  analyzers = { "sonarlintomnisharp.jar" },
  executables = { "dotnet" },
  init_options = function(paths)
    return {
      omnisharpDirectory = vim.fs.joinpath(paths.extension, "omnisharp"),
      csharpOssPath = vim.fs.joinpath(paths.analyzers, "sonarcsharp.jar"),
      csharpEnterprisePath = vim.fs.joinpath(paths.analyzers, "csharpenterprise.jar"),
    }
  end,
  -- The server forwards the on-demand setting under a misspelled key the bridge
  -- never reads, and properties given here replace the ones it computes.
  settings = function(root)
    return {
      sonarlint = {
        analyzerProperties = {
          ["sonar.cs.internal.useNet6"] = "true",
          ["sonar.cs.internal.loadProjectsOnDemand"] = "true",
          ["sonar.cs.internal.solutionPath"] = roslyn.solution(root),
        },
      },
    }
  end,
}
