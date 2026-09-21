local project = require "lang.unity.project"

local M = {}

---@param message string
---@param level? integer
local function notify(message, level) vim.notify(message, level or vim.log.levels.INFO, { title = "Unity" }) end

---@param root string
---@param path string
---@return boolean
local function in_database(root, path)
  return vim.startswith(path, root .. "/Assets/") or vim.startswith(path, root .. "/Packages/")
end

---@param path string
---@return string
local function meta_of(path) return path .. ".meta" end

---@param path string
---@return boolean
function M.is_asset(path)
  if path == "" then return false end
  path = vim.fn.fnamemodify(path, ":p"):gsub("/$", "")
  local root = project.root(path)
  return root ~= nil and in_database(root, path)
end

--- Move an asset's `.meta` alongside it. Unity keys every scene and prefab
--- reference on the GUID inside that file, so an asset that arrives without one
--- is re-imported as a new object and every reference to it goes missing.
---@param source string
---@param destination string
function M.moved(source, destination)
  local root = project.root(source)
  if not root or not in_database(root, source) then return end

  local source_meta = meta_of(source)
  if vim.fn.filereadable(source_meta) ~= 1 then return end

  if not in_database(root, destination) then
    vim.fn.delete(source_meta)
    notify(("Deleted orphaned %s"):format(vim.fs.basename(source_meta)))
    return
  end

  local destination_meta = meta_of(destination)
  if vim.fn.filereadable(destination_meta) == 1 then
    -- Overwriting would replace a GUID something may already reference, so stop
    -- and name both files rather than guess which one is live.
    notify(
      ("%s already exists -- left %s in place. One of the two GUIDs is now wrong."):format(
        vim.fs.basename(destination_meta),
        vim.fs.basename(source_meta)
      ),
      vim.log.levels.WARN
    )
    return
  end

  local ok, err = vim.uv.fs_rename(source_meta, destination_meta)
  if not ok then
    notify(("Could not move %s: %s"):format(vim.fs.basename(source_meta), err), vim.log.levels.ERROR)
    return
  end
  notify(("Moved %s with it -- references preserved"):format(vim.fs.basename(source_meta)))
end

---@param path string
function M.deleted(path)
  local root = project.root(path)
  if not root or not in_database(root, path) then return end

  local meta = meta_of(path)
  if vim.fn.filereadable(meta) ~= 1 then return end
  vim.fn.delete(meta)
  notify(("Deleted %s too"):format(vim.fs.basename(meta)))
end

---@param bufnr integer
---@return string|nil
local function asset_path(bufnr)
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then return nil end
  return vim.fn.fnamemodify(path, ":p")
end

--- Rename through snacks, which tells the language server before the file moves
--- so a C# namespace follows it; the `.meta` is ours to carry afterwards.
---@param bufnr integer
function M.rename(bufnr)
  local path = asset_path(bufnr)
  if not path then return notify("The buffer has no file to rename", vim.log.levels.WARN) end

  require("snacks").rename.rename_file {
    from = path,
    on_rename = function(to, from, ok)
      if ok then M.moved(from, to) end
    end,
  }
end

---@param bufnr integer
function M.delete(bufnr)
  local path = asset_path(bufnr)
  if not path then return notify("The buffer has no file to delete", vim.log.levels.WARN) end

  local meta = meta_of(path)
  local also = vim.fn.filereadable(meta) == 1 and (" and " .. vim.fs.basename(meta)) or ""
  local prompt = ("Delete %s%s?"):format(vim.fs.basename(path), also)
  vim.ui.select({ "No", "Yes" }, { prompt = prompt }, function(choice)
    if choice ~= "Yes" then return end
    if vim.fn.delete(path) ~= 0 then
      return notify(("Could not delete %s"):format(vim.fs.basename(path)), vim.log.levels.ERROR)
    end
    M.deleted(path)
    require("snacks").bufdelete { buf = bufnr, force = true }
    notify(("Deleted %s"):format(vim.fs.basename(path)))
  end)
end

--- Assets whose `.meta` is missing, and `.meta` files whose asset is gone. Both
--- are what a rename done outside this editor leaves behind, and neither is
--- visible until Unity re-imports and the references have already broken.
---@param root string
---@return string[] missing
---@return string[] orphaned
function M.audit(root)
  local assets = root .. "/Assets"
  if vim.fn.isdirectory(assets) ~= 1 then return {}, {} end

  local missing, orphaned = {}, {}
  for name in vim.fs.dir(assets, { depth = 32 }) do
    local base = vim.fs.basename(name)
    -- Unity's own importer skips hidden entries and anything ending in `~`, so
    -- neither has a `.meta` to be missing.
    if not vim.startswith(base, ".") and not vim.endswith(base, "~") then
      local full = assets .. "/" .. name
      if vim.endswith(base, ".meta") then
        if not vim.uv.fs_stat((full:gsub("%.meta$", ""))) then orphaned[#orphaned + 1] = full end
      elseif not vim.uv.fs_stat(meta_of(full)) then
        missing[#missing + 1] = full
      end
    end
  end

  table.sort(missing)
  table.sort(orphaned)
  return missing, orphaned
end

---@param root string
function M.show_audit(root)
  local missing, orphaned = M.audit(root)
  if vim.tbl_isempty(missing) and vim.tbl_isempty(orphaned) then
    return notify "Every asset has its .meta, and every .meta has its asset"
  end

  local items = {}
  for _, path in ipairs(missing) do
    items[#items + 1] =
      { text = path .. " missing meta", file = path, label = "no .meta -- Unity will mint a new GUID" }
  end
  for _, path in ipairs(orphaned) do
    items[#items + 1] = { text = path .. " orphaned meta", file = path, label = "orphaned .meta -- its asset is gone" }
  end

  require("snacks").picker {
    title = "Unity .meta audit",
    items = items,
    format = function(item)
      return { { vim.fs.basename(item.file), "SnacksPickerFile" }, { "  " .. item.label, "SnacksPickerComment" } }
    end,
  }
end

return M
