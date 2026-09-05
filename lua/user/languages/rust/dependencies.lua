local M = {}

local levels = vim.log.levels
local info_cache = {}
local info_waiters = {}
local excluded_names = { alloc = true, core = true, crate = true, self = true, std = true, super = true }

local function notify(message, level) vim.notify(message, level or levels.INFO, { title = "Rust dependencies" }) end

local function trim(value) return (value or ""):gsub("^%s+", ""):gsub("%s+$", "") end

local function cargo(args, cwd, callback)
  local cmd = vim.list_extend({ "cargo" }, args)
  vim.system(cmd, { cwd = cwd, text = true }, function(result)
    vim.schedule(function() callback(result.code == 0, result.stdout or "", result.stderr or "") end)
  end)
end

---@param output string
---@return { name:string, version:string, description:string }[]
function M.parse_search(output)
  local results = {}
  for line in output:gmatch "[^\r\n]+" do
    local name, version, description = line:match '^([%w_-]+)%s*=%s*"([^"]+)"%s*#%s?(.*)$'
    if name then results[#results + 1] = { name = name, version = version, description = description } end
  end
  return results
end

---@param output string
---@return table
function M.parse_info(output)
  local parsed = { features = {} }
  local in_features = false
  for line in output:gmatch "[^\r\n]+" do
    if line == "features:" then
      in_features = true
    elseif line:match "^[%w_.-]+:" then
      in_features = false
      local key, value = line:match "^([%w_.-]+):%s*(.*)$"
      if key then parsed[key:gsub("%-", "_")] = value end
    elseif in_features then
      local enabled, name, members = line:match "^%s*([+ ])([%w_-]+)%s*=%s*%[(.*)%]%s*$"
      if name then
        local list = {}
        for member in members:gmatch "[^,%s]+" do
          list[#list + 1] = member
        end
        parsed.features[#parsed.features + 1] = { name = name, members = list, default = enabled == "+" }
      end
    elseif not parsed.description and line ~= "" and not line:match "^%s" then
      parsed.description = line
    end
  end
  return parsed
end

---@param diagnostic vim.Diagnostic
---@param line string
---@return string?
function M.missing_name(diagnostic, line)
  local code = type(diagnostic.code) == "table" and diagnostic.code.value or diagnostic.code
  if tostring(code) ~= "E0432" and tostring(code) ~= "E0433" then return end
  local message = diagnostic.message or ""
  if
    not (
      message:find("unresolved import", 1, true)
      or message:find("unresolved module or unlinked crate", 1, true)
      or message:find("undeclared crate or module", 1, true)
    )
  then
    return
  end
  local quoted = message:match "unlinked crate [`']([%w_-]+)[`']" or message:match "unresolved import [`']([%w_-]+)[`']"
  local source = line:match "^%s*use%s+::?([%a_][%w_]*)" or line:match "([%a_][%w_]*)::"
  local name = quoted or source
  if name and not excluded_names[name] then return name end
end

---@param name string
---@param callback fun(info:table?)
local function crate_info(name, version, callback)
  local spec = version and (name .. "@" .. version) or name
  if info_cache[spec] then return callback(info_cache[spec]) end
  if info_waiters[spec] then
    info_waiters[spec][#info_waiters[spec] + 1] = callback
    return
  end
  info_waiters[spec] = { callback }
  cargo({ "info", spec, "--registry", "crates-io", "--verbose", "--color", "never" }, nil, function(ok, stdout)
    local value = ok and M.parse_info(stdout) or nil
    info_cache[spec] = value
    local waiters = info_waiters[spec] or {}
    info_waiters[spec] = nil
    for _, waiter in ipairs(waiters) do
      waiter(value)
    end
  end)
end

local function docs_url(item)
  local info = item.info or {}
  if info.documentation and info.documentation ~= "" then return info.documentation end
  return ("https://docs.rs/%s/%s"):format(item.name, item.version)
end

local function open_docs(_, item)
  if item then vim.ui.open(docs_url(item)) end
end

local function info_lines(item)
  local info = item.info
  local lines = {
    "# " .. item.name,
    "",
    item.description ~= "" and item.description or "No description supplied.",
    "",
    "- Version: `" .. item.version .. "`",
  }
  if not info then
    lines[#lines + 1] = "- Loading package details…"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "`<C-o>` opens the full documentation."
    return lines
  end
  for _, field in ipairs { "license", "rust_version", "documentation", "homepage", "repository", "crates.io" } do
    local value = info[field]
    if value and value ~= "" then lines[#lines + 1] = ("- %s: %s"):format(field:gsub("_", " "), value) end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "## Features"
  lines[#lines + 1] = ""
  if #info.features == 0 then
    lines[#lines + 1] = "No published features."
  else
    for _, feature in ipairs(info.features) do
      local members = #feature.members > 0 and (" → " .. table.concat(feature.members, ", ")) or ""
      lines[#lines + 1] = ("- `%s`%s%s"):format(feature.name, feature.default and " (default)" or "", members)
    end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "`<C-o>` opens the full documentation."
  return lines
end

local function display_command(cmd)
  return table.concat(vim.tbl_map(function(part) return vim.fn.shellescape(part) end, cmd), " ")
end

---@param opts { name:string, manifest:string, kind?:string, rename?:string, target?:string, features?:string[], default_features?:boolean }
---@return string[]
function M.add_args(opts)
  local args = { "add", opts.name, "--manifest-path", opts.manifest }
  if opts.kind == "dev" then args[#args + 1] = "--dev" end
  if opts.kind == "build" then args[#args + 1] = "--build" end
  if opts.rename then vim.list_extend(args, { "--rename", opts.rename }) end
  if opts.target then vim.list_extend(args, { "--target", opts.target }) end
  if opts.default_features == false then args[#args + 1] = "--no-default-features" end
  if opts.default_features == true then args[#args + 1] = "--default-features" end
  if opts.features and #opts.features > 0 then
    vim.list_extend(args, { "--features", table.concat(opts.features, ",") })
  end
  return args
end

local function run_add(opts)
  local args = M.add_args(opts)
  local cmd = vim.list_extend({ "cargo" }, vim.deepcopy(args))
  local message = ("Add `%s`?\n\n%s\n\nManifest: %s"):format(
    opts.rename or opts.name,
    display_command(cmd),
    opts.manifest
  )
  if vim.fn.confirm(message, "&Add\n&Cancel", 2, "Question") ~= 1 then return end
  require("user.languages.rust.executor").executor.execute_command("cargo", args, vim.fs.dirname(opts.manifest), {})
end

local function feature_picker(item, add_opts)
  local info = item.info
  if not info then return notify("Could not load features for " .. item.name, levels.WARN) end
  local existing = {}
  for _, name in ipairs(add_opts.features or {}) do
    existing[name] = true
  end
  local choices = {}
  if add_opts.default_features == false then
    choices[#choices + 1] = { text = "Enable default features", default_action = true, name = "default" }
  else
    choices[#choices + 1] = { text = "Disable default features", default_action = false, name = "no-default" }
  end
  for _, feature in ipairs(info.features) do
    if feature.name ~= "default" then
      choices[#choices + 1] = {
        text = (existing[feature.name] and "✓ " or "  ") .. feature.name,
        name = feature.name,
        members = feature.members,
        existing = existing[feature.name],
      }
    end
  end
  require("snacks").picker {
    title = "Features for " .. item.name .. " — <Tab> select, <Enter> continue",
    items = choices,
    format = "text",
    preview = function(ctx)
      local selected = ctx.item
      local lines = { "# " .. selected.name, "" }
      if selected.default_action ~= nil then
        lines[#lines + 1] = selected.default_action and "Enable the crate's default feature set."
          or "Disable the crate's default feature set."
      elseif selected.existing then
        lines[#lines + 1] = "Already enabled; selecting it again is harmless."
      else
        lines[#lines + 1] = "Selecting this feature adds it to the dependency."
      end
      if selected.members and #selected.members > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Enables:"
        for _, member in ipairs(selected.members) do
          lines[#lines + 1] = "- `" .. member .. "`"
        end
      end
      ctx.preview:set_lines(lines)
      vim.bo[ctx.buf].filetype = "markdown"
    end,
    confirm = function(picker)
      local selected = picker:selected()
      picker:close()
      local features, default_features = {}, nil
      for _, choice in ipairs(selected) do
        if choice.default_action ~= nil then
          default_features = choice.default_action
        elseif not choice.existing then
          features[#features + 1] = choice.name
        end
      end
      if add_opts.existing and #features == 0 and default_features == nil then
        return notify "No feature changes selected"
      end
      add_opts.features = features
      add_opts.default_features = default_features
      vim.schedule(function() run_add(add_opts) end)
    end,
    layout = { preset = "default" },
  }
end

local function choose_kind(item, manifest)
  local kinds = {
    { label = "Dependency", kind = nil },
    { label = "Development dependency", kind = "dev" },
    { label = "Build dependency", kind = "build" },
  }
  vim.ui.select(kinds, {
    prompt = "Add " .. item.name .. " as",
    format_item = function(choice) return choice.label end,
  }, function(choice)
    if not choice then return end
    feature_picker(item, { name = item.name, manifest = manifest, kind = choice.kind })
  end)
end

local function select_workspace_package(metadata, callback)
  local members = {}
  local ids = {}
  for _, id in ipairs(metadata.workspace_members or {}) do
    ids[id] = true
  end
  for _, package in ipairs(metadata.packages or {}) do
    if ids[package.id] then members[#members + 1] = package end
  end
  vim.ui.select(members, {
    prompt = "Choose the workspace package to modify",
    format_item = function(package) return ("%s — %s"):format(package.name, package.manifest_path) end,
  }, function(package) callback(package and package.manifest_path or nil) end)
end

local function resolve_manifest(callback)
  local file = vim.api.nvim_buf_get_name(0)
  local cwd = file ~= "" and vim.fs.dirname(file) or vim.fn.getcwd()
  cargo({ "locate-project", "--message-format", "plain", "--color", "never" }, cwd, function(ok, stdout, stderr)
    if not ok then return notify(trim(stderr) ~= "" and trim(stderr) or "No Cargo project found", levels.ERROR) end
    local manifest = trim(stdout)
    local text = table.concat(vim.fn.readfile(manifest, "", 200), "\n")
    if text:match "\n?%s*%[package%]%s*\n" then return callback(manifest) end
    cargo(
      { "metadata", "--no-deps", "--format-version", "1", "--manifest-path", manifest, "--color", "never" },
      cwd,
      function(meta_ok, json, meta_err)
        if not meta_ok then return notify(trim(meta_err), levels.ERROR) end
        local decoded_ok, metadata = pcall(vim.json.decode, json)
        if not decoded_ok then return notify("Cargo returned invalid workspace metadata", levels.ERROR) end
        select_workspace_package(metadata, callback)
      end
    )
  end)
end

local function crate_picker(results, on_confirm)
  local items = {}
  for _, result in ipairs(results) do
    items[#items + 1] = {
      text = ("%-28s %-12s %s"):format(result.name, result.version, result.description),
      name = result.name,
      version = result.version,
      description = result.description,
    }
  end
  require("snacks").picker {
    title = "Cargo crates — <Enter> choose, <C-o> docs",
    items = items,
    format = "text",
    preview = function(ctx)
      ctx.preview:set_title(ctx.item.name)
      ctx.preview:set_lines(info_lines(ctx.item))
      vim.bo[ctx.buf].filetype = "markdown"
      if not ctx.item.info and not ctx.item.loading then
        ctx.item.loading = true
        crate_info(ctx.item.name, ctx.item.version, function(info)
          ctx.item.loading, ctx.item.info = false, info
          if ctx.picker:current() == ctx.item then pcall(function() ctx.picker.preview:refresh(ctx.picker) end) end
        end)
      end
    end,
    confirm = function(picker, item)
      if not item then return end
      picker:close()
      local function proceed()
        if not item.info then return notify("Could not load package details for " .. item.name, levels.ERROR) end
        vim.schedule(function() on_confirm(item) end)
      end
      if item.info then
        proceed()
      else
        crate_info(item.name, item.version, function(info)
          item.info = info
          proceed()
        end)
      end
    end,
    actions = { open_crate_docs = open_docs },
    win = {
      input = { keys = { ["<C-o>"] = { "open_crate_docs", mode = { "i", "n" }, desc = "open docs.rs" } } },
      list = { keys = { ["<C-o>"] = { "open_crate_docs", mode = { "i", "n" }, desc = "open docs.rs" } } },
    },
    layout = { preset = "default" },
  }
end

local function search_registry(query, callback)
  notify("Searching crates.io for “" .. query .. "”…")
  cargo({ "search", query, "--limit", "40", "--color", "never" }, nil, function(ok, stdout, stderr)
    if not ok then return notify(trim(stderr), levels.ERROR) end
    local results = M.parse_search(stdout)
    if #results == 0 then return notify("No crates found for “" .. query .. "”", levels.WARN) end
    callback(results)
  end)
end

function M.search(query)
  local function start(value)
    value = trim(value)
    if value == "" then return end
    search_registry(value, function(results)
      resolve_manifest(function(manifest)
        if manifest then crate_picker(results, function(item) choose_kind(item, manifest) end) end
      end)
    end)
  end
  if query then return start(query) end
  vim.ui.input({ prompt = "Search crates.io: " }, start)
end

function M.add_named(name)
  search_registry(name, function(results)
    local normalized = name:gsub("_", "-"):lower()
    for _, result in ipairs(results) do
      if result.name:gsub("_", "-"):lower() == normalized then
        return resolve_manifest(function(manifest)
          if not manifest then return end
          crate_info(result.name, result.version, function(info)
            if not info then return notify("Could not load package details for " .. result.name, levels.ERROR) end
            result.info = info
            choose_kind(result, manifest)
          end)
        end)
      end
    end
    crate_picker(results, function(item)
      resolve_manifest(function(manifest)
        if manifest then choose_kind(item, manifest) end
      end)
    end)
  end)
end

local function dependency_picker(package)
  local dependencies = {}
  for _, dep in ipairs(package.dependencies or {}) do
    local crates_io = not dep.path and (not dep.source or dep.source:find("crates.io", 1, true))
    if crates_io then
      dependencies[#dependencies + 1] = {
        text = (dep.rename and (dep.rename .. " (" .. dep.name .. ")") or dep.name),
        name = dep.name,
        rename = dep.rename,
        kind = dep.kind,
        target = dep.target,
        existing_features = dep.features or {},
        default_features = dep.uses_default_features,
      }
    end
  end
  if #dependencies == 0 then return notify("This package has no crates.io dependencies", levels.WARN) end
  vim.ui.select(
    dependencies,
    { prompt = "Browse dependency features", format_item = function(dep) return dep.text end },
    function(dep)
      if not dep then return end
      crate_info(dep.name, nil, function(info)
        if not info then return notify("Could not load package details for " .. dep.name, levels.ERROR) end
        feature_picker({ name = dep.name, version = info.version or "latest", info = info }, {
          name = dep.name,
          rename = dep.rename,
          manifest = package.manifest_path,
          kind = dep.kind,
          target = dep.target,
          features = dep.existing_features,
          default_features = dep.default_features,
          existing = true,
        })
      end)
    end
  )
end

function M.features()
  resolve_manifest(function(manifest)
    if not manifest then return end
    cargo(
      { "metadata", "--no-deps", "--format-version", "1", "--manifest-path", manifest, "--color", "never" },
      vim.fs.dirname(manifest),
      function(ok, json, stderr)
        if not ok then return notify(trim(stderr), levels.ERROR) end
        local decoded_ok, metadata = pcall(vim.json.decode, json)
        if not decoded_ok then return notify("Cargo returned invalid package metadata", levels.ERROR) end
        for _, package in ipairs(metadata.packages or {}) do
          if vim.fs.normalize(package.manifest_path) == vim.fs.normalize(manifest) then
            return dependency_picker(package)
          end
        end
        select_workspace_package(metadata, function(selected)
          if not selected then return end
          for _, package in ipairs(metadata.packages or {}) do
            if package.manifest_path == selected then return dependency_picker(package) end
          end
        end)
      end
    )
  end)
end

function M.offer_quick_fix(fallback)
  if vim.bo.filetype ~= "rust" then return false end
  if vim.api.nvim_get_mode().mode:match "^[vV\22]" then return false end
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = vim.api.nvim_get_current_line()
  local name
  for _, diagnostic in ipairs(vim.diagnostic.get(0, { lnum = cursor[1] - 1 })) do
    local finish = diagnostic.end_col or diagnostic.col
    if diagnostic.col <= cursor[2] and cursor[2] <= finish then
      name = M.missing_name(diagnostic, line)
      if name then break end
    end
  end
  if not name then return false end
  local choices = { "Add Cargo dependency `" .. name .. "`", "Show other code actions" }
  vim.ui.select(choices, { prompt = "Unresolved Rust crate" }, function(choice)
    if choice == choices[1] then
      M.add_named(name)
    elseif choice == choices[2] then
      fallback()
    end
  end)
  return true
end

return M
