-- C++ scaffolding is intentionally picker-only through `<Leader>ra`; the
-- command remains useful from scripts and from a non-C++ buffer in a project.
---@type LazySpec
return {
  "AstroNvim/astrocore",
  opts = function(_, opts)
    opts.commands = opts.commands or {}
    opts.commands.CppNew = {
      function(args) require("user.languages.cpp.scaffold").create(args.args ~= "" and args.args or "class") end,
      desc = "Create a C++ class, interface or class template",
      nargs = "?",
      complete = function() return { "class", "interface", "template" } end,
    }
  end,
}
