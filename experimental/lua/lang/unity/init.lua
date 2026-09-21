vim.filetype.add {
  extension = {
    unity = "yaml",
    prefab = "yaml",
    asset = "yaml",
    mat = "yaml",
    anim = "yaml",
    controller = "yaml",
    overrideController = "yaml",
    physicsMaterial = "yaml",
    physicsMaterial2D = "yaml",
    meta = "yaml",
    asmdef = "json",
    asmref = "json",
    shader = "hlsl",
    compute = "hlsl",
    cginc = "hlsl",
    uxml = "xml",
    uss = "css",
  },
}

-- `core` may not name a language, so the module owns this one. Both calls are
-- cheap and idempotent, and both return immediately outside a Unity project.
vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
  group = vim.api.nvim_create_augroup("lang_unity_project", { clear = true }),
  callback = function(args)
    local root = require("lang.unity.project").root(args.buf)
    if not root then return end
    require("lang.unity.shim").register(root)
    require("lang.unity.state").attach(args.buf)
  end,
})

---@type lang.Module
return {
  -- Only the debug layer reads this: `unity` declares no server, because
  -- `csharp` owns roslyn_ls for the same buffers.
  ft = { "cs" },

  dap = {
    adapters = {
      vstuc = function(callback, config) require("lang.unity.dap").adapter(callback, config) end,
    },
    configurations = function(bufnr) return require("lang.unity.dap").configurations(bufnr) end,
  },

  actions = require "lang.unity.actions",
}
