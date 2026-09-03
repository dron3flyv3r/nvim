local M = { id = "cpp", name = "C/C++", priority = 50 }

function M.detect(ctx)
  return vim.tbl_contains({ "c", "cpp", "objc", "objcpp", "cuda" }, ctx.filetype) and "current source file" or false
end

local function create(kind)
  return function() require("user.languages.cpp.scaffold").create(kind) end
end

function M.actions()
  return {
    { id = "cpp.new_class", label = "Create class (.h + .cpp)", category = "Create", run = create "class" },
    {
      id = "cpp.new_interface",
      label = "Create interface (abstract base)",
      category = "Create",
      run = create "interface",
    },
    { id = "cpp.new_template", label = "Create class template", category = "Create", run = create "template" },
  }
end

return M
