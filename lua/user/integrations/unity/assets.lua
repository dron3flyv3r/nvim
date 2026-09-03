local M = {}

---@param root string
---@param path string
---@return boolean
local function is_asset(root, path)
  return vim.startswith(path, root .. "/Assets/") or vim.startswith(path, root .. "/Packages/")
end

---@param path string
---@return string
local function meta_of(path) return path .. ".meta" end

--- Move an asset's `.meta` file alongside it.
---@param source string
---@param destination string
function M.moved(source, destination)
  local root = require("user.integrations.unity").root(source)
  if not root or not is_asset(root, source) then return end

  local source_meta = meta_of(source)
  if vim.fn.filereadable(source_meta) ~= 1 then return end

  -- Moving into `Library/` or out of the project: the `.meta` should not follow,
  -- it should be deleted, because the asset has left the asset database.
  if not is_asset(root, destination) then
    vim.fn.delete(source_meta)
    vim.notify(("Deleted orphaned %s"):format(vim.fs.basename(source_meta)), vim.log.levels.INFO, { title = "Unity" })
    return
  end

  local destination_meta = meta_of(destination)
  if vim.fn.filereadable(destination_meta) == 1 then
    -- Unity already made one at the target. Ours would overwrite a GUID that
    -- something may already reference, so stop and say so rather than guess.
    vim.notify(
      ("%s already exists -- left %s in place. One of the two GUIDs is now wrong."):format(
        vim.fs.basename(destination_meta),
        vim.fs.basename(source_meta)
      ),
      vim.log.levels.WARN,
      { title = "Unity" }
    )
    return
  end

  local ok, err = vim.uv.fs_rename(source_meta, destination_meta)
  if not ok then
    vim.notify(
      ("Could not move %s: %s"):format(vim.fs.basename(source_meta), err),
      vim.log.levels.ERROR,
      { title = "Unity" }
    )
    return
  end
  vim.notify(
    ("Moved %s with it -- scene references preserved"):format(vim.fs.basename(source_meta)),
    vim.log.levels.INFO,
    { title = "Unity" }
  )
end

--- Delete an asset's `.meta` file along with it.
---@param path string
function M.deleted(path)
  local root = require("user.integrations.unity").root(path)
  if not root or not is_asset(root, path) then return end

  local meta = meta_of(path)
  if vim.fn.filereadable(meta) ~= 1 then return end
  vim.fn.delete(meta)
  vim.notify(("Deleted %s too"):format(vim.fs.basename(meta)), vim.log.levels.INFO, { title = "Unity" })
end

---@param bufnr integer
---@return string|nil name
---@return boolean is_mono Whether it derives from MonoBehaviour or ScriptableObject.
local function first_type(bufnr)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "c_sharp")
  if not ok or not parser then return nil, false end
  local tree = parser:parse()[1]
  if not tree then return nil, false end

  local DECLARATIONS = {
    class_declaration = true,
    struct_declaration = true,
    record_declaration = true,
    interface_declaration = true,
    enum_declaration = true,
  }
  -- A namespace wraps its members in a `declaration_list`, so both have to be
  -- descended through to reach the type.
  local CONTAINERS = {
    namespace_declaration = true,
    file_scoped_namespace_declaration = true,
    declaration_list = true,
  }

  ---@param node TSNode
  ---@return TSNode|nil
  local function find(node)
    for child in node:iter_children() do
      local type = child:type()
      if DECLARATIONS[type] then return child end
      if CONTAINERS[type] then
        local found = find(child)
        if found then return found end
      end
    end
  end

  local declaration = find(tree:root())
  if not declaration then return nil, false end

  local name_node = declaration:field "name"
  local name = name_node[1] and vim.treesitter.get_node_text(name_node[1], bufnr) or nil

  local is_mono = false
  for child in declaration:iter_children() do
    if child:type() == "base_list" then
      local bases = vim.treesitter.get_node_text(child, bufnr)
      is_mono = bases:find "MonoBehaviour" ~= nil or bases:find "ScriptableObject" ~= nil
      break
    end
  end

  return name, is_mono
end

---@param bufnr integer
function M.check_class_name(bufnr)
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" or not vim.endswith(path, ".cs") then return end
  local root = require("user.integrations.unity").root(path)
  if not root or not is_asset(root, path) then return end

  local name, is_mono = first_type(bufnr)
  if not name or not is_mono then return end

  local expected = vim.fn.fnamemodify(path, ":t:r")
  if name == expected then return end

  vim.notify(
    ("Class `%s` is in %s.cs -- Unity will refuse to attach it as a component.\nRename one of the two so they match."):format(
      name,
      expected
    ),
    vim.log.levels.WARN,
    { title = "Unity" }
  )
end

return M
