local M = {}

---@param locations lsp.Location[]
---@param client vim.lsp.Client?
local function pick(locations, client)
  local items = {}
  for _, entry in ipairs(vim.lsp.util.locations_to_items(locations, client and client.offset_encoding or "utf-16")) do
    items[#items + 1] = {
      text = entry.filename .. " " .. entry.text,
      file = entry.filename,
      pos = { entry.lnum, entry.col - 1 },
      line = entry.text,
    }
  end

  if #items == 0 then
    vim.notify("No locations", vim.log.levels.INFO, { title = "rust" })
  elseif #items == 1 then
    vim.cmd.edit(items[1].file)
    pcall(vim.api.nvim_win_set_cursor, 0, { items[1].pos[1], items[1].pos[2] })
  else
    require("snacks").picker.pick { items = items, format = "file", focus = "list", title = "Code Lens" }
  end
end

-- rustaceanvim's own handler answers every lens with vim.lsp.buf.implementation,
-- so a "3 references" lens navigates to implementations instead. The lens already
-- carries its locations in arguments[3]; this shows those, in the picker the rest
-- of the gr family uses.
function M.setup()
  vim.api.nvim_create_autocmd("FileType", {
    group = vim.api.nvim_create_augroup("lang_rust_lens", { clear = true }),
    pattern = "rust",
    callback = function()
      -- rustaceanvim registers from its ftplugin, which runs on this same
      -- event; scheduling puts the override after it rather than under it.
      vim.schedule(function()
        vim.lsp.commands["rust-analyzer.showReferences"] = function(command, ctx)
          pick(command.arguments and command.arguments[3] or {}, vim.lsp.get_client_by_id(ctx.client_id))
        end
      end)
    end,
  })
end

return M
