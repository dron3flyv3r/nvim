local M = {}

---@param group string
---@param text string
---@return string
local function highlighted(group, text) return ("%%#%s#%s%%#StatusLine#"):format(group, text) end

---@param ctx core.statusline.Context
---@return string?
local function text(ctx)
  local dict = vim.b[ctx.bufnr].gitsigns_status_dict
  if type(dict) ~= "table" or not dict.head or dict.head == "" then return nil end

  local out = { highlighted("Comment", " " .. dict.head) }
  if ctx.width >= 100 then
    local counts = {
      { dict.added, "GitSignsAdd", "+" },
      { dict.changed, "GitSignsChange", "~" },
      { dict.removed, "GitSignsDelete", "-" },
    }
    for _, item in ipairs(counts) do
      if type(item[1]) == "number" and item[1] > 0 then
        out[#out + 1] = highlighted(item[2], item[3] .. item[1])
      end
    end
  end
  return table.concat(out, " ")
end

function M.setup()
  require("core.statusline").register("git", { side = "left", order = 10, min_width = 60, raw = true, text = text })

  -- The counts arrive with the signs, not with the attach, and that update is
  -- not itself a redraw.
  vim.api.nvim_create_autocmd("User", {
    group = vim.api.nvim_create_augroup("git_status", { clear = true }),
    pattern = "GitSignsUpdate",
    desc = "Redraw the statusline when the hunk counts change",
    callback = function() vim.cmd.redrawstatus() end,
  })
end

return M
