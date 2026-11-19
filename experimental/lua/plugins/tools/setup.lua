local M = {}

---@param language string
---@param features {label: string, package?: string, parser?: string, ready?: fun(): boolean}[]
function M.open(language, features)
  local items = {}
  for _, feature in ipairs(features) do
    local ready
    if feature.parser then
      ready = vim.treesitter.language.add(feature.parser)
        and vim.treesitter.query.get(feature.parser, "highlights") ~= nil
    else
      ready = feature.ready()
    end
    local tool = feature.parser and (feature.parser .. " parser") or feature.package
    items[#items + 1] = {
      feature = feature,
      ready = ready,
      label = ("%s — %s (%s)"):format(feature.label, ready and "Installed" or "Install", tool),
    }
  end
  vim.ui.select(items, {
    prompt = language .. " tooling",
    format_item = function(item) return item.label end,
  }, function(item)
    if not item or item.ready then return end
    local feature = item.feature
    if feature.parser then
      require("core.task").run {
        name = "Install " .. feature.parser .. " parser",
        cmd = { "just", "install-parser", feature.parser },
        cwd = vim.fn.stdpath "config",
        on_exit = function(task)
          if task.status == "success" then vim.notify "Restart Neovim to use the installed parser" end
        end,
      }
    else
      vim.cmd.MasonInstall(feature.package)
      vim.notify "Restart Neovim after installation finishes"
    end
  end)
end

return M
