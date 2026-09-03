local M = {}

local SKIP_DIRS = {
  ["build"] = true,
  ["external"] = true,
  ["third_party"] = true,
  ["thirdparty"] = true,
  ["vendor"] = true,
  ["deps"] = true,
  ["subprojects"] = true,
  [".cache"] = true,
  [".git"] = true,
  ["node_modules"] = true,
}

--- Where the project starts. `CMakeLists.txt` first, because that is also the
--- file the source list has to be written into, and `.git` last because a
--- monorepo's root is usually too far up to be the right answer.
local ROOT_MARKERS = { "CMakeLists.txt", "compile_commands.json", ".git" }

---@param start string
---@return string
local function project_root(start)
  local found = vim.fs.find(ROOT_MARKERS, { path = start, upward = true, limit = 1 })[1]
  return found and vim.fs.dirname(found) or start
end

---@param name string
---@return string
local function to_pascal(name)
  if name:find "%u" then return name end
  local pascal = name:gsub("(%a)([%w]*)", function(head, tail) return head:upper() .. tail end)
  return (pascal:gsub("[_%-%s]", ""))
end

---@param name string
---@return string
local function to_snake(name)
  local snake = name:gsub("(%l)(%u)", "%1_%2")
  snake = snake:gsub("(%u)(%u%l)", "%1_%2")
  snake = snake:gsub("[%-%s]+", "_")
  return (snake:lower())
end

---@param root string
---@param bufdir string?
---@return string[] paths
local function sample_headers(root, bufdir)
  local dirs = { bufdir, root, vim.fs.joinpath(root, "src"), vim.fs.joinpath(root, "include") }
  local seen_dir, found = {}, {}

  for _, dir in ipairs(dirs) do
    if dir and not seen_dir[dir] and vim.uv.fs_stat(dir) then
      seen_dir[dir] = true
      for name, entry_type in vim.fs.dir(dir, { depth = 2 }) do
        local top = name:match "^([^/]+)/"
        if entry_type == "file" and not (top and SKIP_DIRS[top]) and name:match "%.h[px]*$" then
          table.insert(found, vim.fs.joinpath(dir, name))
          if #found >= 24 then return found end
        end
      end
    end
  end
  return found
end

--- Everything the templates need to know about how this project is written.
---@class CppConventions
---@field snake boolean       file names are snake_case rather than PascalCase
---@field header_ext string   ".h" or ".hpp"
---@field source_ext string   ".cpp", ".cc" or ".cxx"
---@field pragma boolean      `#pragma once` rather than an #ifndef guard
---@field namespace string?   the namespace the project's headers open, if any

--- Read the conventions off the project, falling back to this user's own house
--- style when there is nothing to read (a project whose first header is the one
--- being created right now).
---@param root string
---@param bufdir string?
---@return CppConventions
local function conventions(root, bufdir)
  local headers = sample_headers(root, bufdir)

  local snake, pascal = 0, 0
  local ext_count = { [".h"] = 0, [".hpp"] = 0 }
  local pragma, ifndef = 0, 0
  local namespaces = {}

  for _, path in ipairs(headers) do
    local base = vim.fs.basename(path)
    local stem, ext = base:match "^(.*)(%.h[px]*)$"
    if stem then
      if stem:find "%u" then
        pascal = pascal + 1
      else
        snake = snake + 1
      end
      ext_count[ext] = (ext_count[ext] or 0) + 1
    end

    -- The guard and the namespace are both in the first few lines, so there is
    -- no reason to read a 4000-line header to find them.
    local lines = {}
    local fd = io.open(path, "r")
    if fd then
      for _ = 1, 40 do
        local line = fd:read "l"
        if not line then break end
        table.insert(lines, line)
      end
      fd:close()
    end

    for _, line in ipairs(lines) do
      if line:match "^%s*#pragma%s+once" then
        pragma = pragma + 1
        break
      elseif line:match "^%s*#ifndef%s+%w" then
        ifndef = ifndef + 1
        break
      end
    end

    for _, line in ipairs(lines) do
      -- Only a named, non-nested namespace opening at column zero. `namespace
      -- detail {` nested inside another one would be the wrong answer, and an
      -- anonymous `namespace {` is not a name at all.
      local ns = line:match "^namespace%s+([%w_:]+)%s*{"
      if ns then
        namespaces[ns] = (namespaces[ns] or 0) + 1
        break
      end
    end
  end

  local best_ns, best_ns_count = nil, 0
  for ns, count in pairs(namespaces) do
    if count > best_ns_count then
      best_ns, best_ns_count = ns, count
    end
  end

  return {
    -- Ties and empty projects go to snake_case: it is what SOPA-ESP32-MK3
    -- uses, and it is the only convention this config has ever seen here.
    snake = snake >= pascal,
    header_ext = (ext_count[".hpp"] or 0) > (ext_count[".h"] or 0) and ".hpp" or ".h",
    -- `.cc`/`.cxx` are not detected: every C++ file in every project here is
    -- `.cpp`, and a wrong guess costs a rename.
    source_ext = ".cpp",
    pragma = ifndef == 0 or pragma >= ifndef,
    -- A namespace only counts if most of the project's headers agree on it.
    -- One file with a `namespace detail` should not wrap every new class.
    namespace = (best_ns_count * 2 > #headers) and best_ns or nil,
  }
end

---@param root string
---@param bufdir string?
---@return string header_dir, string source_dir
local function destinations(root, bufdir)
  local source_dir = bufdir
  if not source_dir or not vim.uv.fs_stat(source_dir) then
    local src = vim.fs.joinpath(root, "src")
    source_dir = vim.uv.fs_stat(src) and src or root
  end

  local include = vim.fs.joinpath(root, "include")
  if not vim.uv.fs_stat(include) then return source_dir, source_dir end

  -- `include/<project>/foo.h` is the convention that makes the include in
  -- other projects read `#include <project/foo.h>`; if such a directory
  -- exists, headers go inside it rather than beside it.
  local project_subdir = vim.fs.joinpath(include, vim.fs.basename(root))
  if vim.uv.fs_stat(project_subdir) then return project_subdir, source_dir end
  return include, source_dir
end

---@param root string
---@param header_path string
---@param source_dir string
---@return string
local function include_spelling(root, header_path, source_dir)
  local header_dir = vim.fs.dirname(header_path)
  if header_dir == source_dir then return vim.fs.basename(header_path) end

  local include = vim.fs.joinpath(root, "include")
  local relative = header_path:sub(#include + 2)
  if vim.startswith(header_path, include .. "/") then return relative end
  return vim.fs.basename(header_path)
end

---@param input string
---@return string? subdir  nil when no slash was typed at all
---@return string name
---@return boolean from_root
local function split_path(input)
  local dir, name = input:match "^(.*)/([^/]*)$"
  if not dir then return nil, input, false end
  return (dir:gsub("^/+", "")), name, vim.startswith(dir, "/")
end

---@param path string
---@return string? nil when the path climbs above `/`
local function collapse(path)
  local parts = {}
  for part in path:gmatch "[^/]+" do
    if part == ".." then
      if #parts == 0 then return nil end
      table.remove(parts)
    elseif part ~= "." then
      table.insert(parts, part)
    end
  end
  return "/" .. table.concat(parts, "/")
end

---@param root string
---@param path string
---@return boolean
local function inside(root, path) return path == root or vim.startswith(path, root .. "/") end

--- Open the guard, as a list of lines, plus the lines that close it.
---@param conv CppConventions
---@param class string
---@return string[] open, string[] close
local function guard(conv, class)
  if conv.pragma then return { "#pragma once", "" }, {} end
  local macro = to_snake(class):upper() .. "_" .. conv.header_ext:sub(2):upper() .. "_"
  return { "#ifndef " .. macro, "#define " .. macro, "" }, { "", "#endif  // " .. macro }
end

--- Wrap a class body in the project's namespace, if it has one.
---@param conv CppConventions
---@param body string[]
---@return string[]
local function wrap_namespace(conv, body)
  if not conv.namespace then return body end
  local lines = { "namespace " .. conv.namespace .. " {", "" }
  vim.list_extend(lines, body)
  vim.list_extend(lines, { "", "}  // namespace " .. conv.namespace })
  return lines
end

---@type table<string, fun(class: string, conv: CppConventions): string[], string[]?>
local TEMPLATES = {
  class = function(class, conv)
    local header = wrap_namespace(conv, {
      "class " .. class .. " {",
      "public:",
      "  " .. class .. "();",
      "",
      "private:",
      "};",
    })
    local source = wrap_namespace(conv, {
      class .. "::" .. class .. "() {}",
    })
    return header, source
  end,

  interface = function(class, conv)
    return wrap_namespace(conv, {
      "class " .. class .. " {",
      "public:",
      "  virtual ~" .. class .. "() = default;",
      "",
      "  // virtual void method() = 0;",
      "};",
    })
  end,

  template = function(class, conv)
    return wrap_namespace(conv, {
      "template <typename T>",
      "class " .. class .. " {",
      "public:",
      "  " .. class .. "() = default;",
      "",
      "private:",
      "};",
    })
  end,
}

---@param root string
---@param source_path string
---@return string? target the target the file was added to, nil if nothing was written
---@return "none"|"indirect"|"nomatch"|nil why nothing was written
local function add_to_cmake(root, source_path)
  local cmake_path = vim.fs.joinpath(root, "CMakeLists.txt")
  if not vim.uv.fs_stat(cmake_path) then return nil, "none" end

  local ok, lines = pcall(vim.fn.readfile, cmake_path)
  if not ok or type(lines) ~= "table" then return nil, "none" end

  local indirect = false
  for _, line in ipairs(lines) do
    if line:find "GLOB" then
      indirect = true
      break
    end
  end

  local rel = source_path:sub(#root + 2)

  --- One pass over every target block, looking for one that lists a source from
  --- `match_dir`. Writes the file and returns the target on the first hit.
  ---@param match_dir string
  ---@return string?
  local function insert_beside(match_dir)
    local i = 1
    while i <= #lines do
      local target = lines[i]:match "^%s*add_executable%s*%(%s*([%w_%-${}]+)"
        or lines[i]:match "^%s*add_library%s*%(%s*([%w_%-${}]+)"
        or lines[i]:match "^%s*target_sources%s*%(%s*([%w_%-${}]+)"

      if target then
        -- Collect the block by paren balance, so a source list spanning ten
        -- lines is one unit and a nested `$<...>` generator expression does not
        -- end it early.
        local depth, last = 0, i
        for j = i, #lines do
          local _, opens = lines[j]:gsub("%(", "")
          local _, closes = lines[j]:gsub("%)", "")
          depth = depth + opens - closes
          last = j
          if depth <= 0 then break end
        end

        local _, name_end = lines[i]:find(target, 1, true)
        local variable = lines[i]:sub((name_end or 0) + 1):find "%${" ~= nil
        for j = i + 1, last do
          if lines[j]:find "%${" then variable = true end
        end
        for j = i, last do
          if lines[j]:find "GLOB" then variable = true end
        end
        indirect = indirect or variable

        if not variable then
          local first_after, last_same, indent = nil, nil, nil

          for j = i, last do
            for token in lines[j]:gmatch "[%w_%-%./${}]+" do
              -- Checking the extension on the whole token rather than matching
              -- it inside the pattern: an unanchored `%.c[cpx]` happily matches
              -- the `.cp` of `.cpp` and yields a truncated path.
              local is_source = token:match "%.cpp$" or token:match "%.cc$" or token:match "%.cxx$"
              if is_source and vim.fs.dirname(token) == match_dir then
                -- Indent is copied from a continuation line, never from the
                -- `add_executable(` line itself -- that one's leading whitespace
                -- is the block's, not the list's.
                if j > i then indent = indent or lines[j]:match "^(%s*)" end
                if token > rel and not first_after then first_after = j end
                last_same = j
              end
            end
          end

          if last_same then
            if i == last then
              -- Single-line form: `add_executable(app src/main.cpp)`. Splice the
              -- path in before the closing paren rather than adding a line.
              lines[i] = lines[i]:gsub("%s*%)%s*$", " " .. rel .. ")")
            else
              table.insert(lines, first_after or last_same + 1, (indent or "    ") .. rel)
            end
            vim.fn.writefile(lines, cmake_path)
            return target
          end
        end

        i = last + 1
      else
        i = i + 1
      end
    end
    return nil
  end

  local dir = vim.fs.dirname(rel)
  while true do
    local target = insert_beside(dir)
    if target then return target end
    -- `dirname` of a bare name is ".", which is the root's own listing and the
    -- last thing worth trying; it is also its own parent, so it has to end the
    -- loop rather than be walked past.
    if dir == "." then break end
    dir = vim.fs.dirname(dir)
  end

  return nil, indirect and "indirect" or "nomatch"
end

--- Create a class, an interface or a class template.
---@param kind "class"|"interface"|"template"
function M.create(kind)
  local build = TEMPLATES[kind]
  if not build then return vim.notify("Unknown template: " .. tostring(kind), vim.log.levels.ERROR) end

  local bufname = vim.api.nvim_buf_get_name(0)
  local bufdir = bufname ~= "" and vim.fs.dirname(bufname) or nil
  -- A buffer with no file behind it (the dashboard, a terminal) has no useful
  -- directory, and neither does one outside the project.
  if bufdir and not vim.uv.fs_stat(bufdir) then bufdir = nil end

  local root = project_root(bufdir or vim.uv.cwd())

  vim.ui.input({ prompt = "New " .. kind .. " (name or path/Name): " }, function(input)
    if not input or input:match "^%s*$" then return end
    input = vim.trim(input)

    -- Only the last segment is the class; the rest is where to put it, and is
    -- created if it does not exist yet.
    local subdir, name, from_root = split_path(input)

    local class = to_pascal(name)
    if not class:match "^[%a_][%w_]*$" then
      return vim.notify(
        ("%q is not a valid C++ identifier"):format(name),
        vim.log.levels.ERROR,
        { title = "New " .. kind }
      )
    end

    local conv = conventions(root, bufdir)
    local header_dir, source_dir = destinations(root, bufdir)

    if subdir then
      local base_header, base_source = header_dir, source_dir
      if from_root then
        base_header, base_source = root, root
      end

      local resolved_header = collapse(vim.fs.joinpath(base_header, subdir))
      local resolved_source = collapse(vim.fs.joinpath(base_source, subdir))

      if
        not resolved_header
        or not resolved_source
        or not inside(root, resolved_header)
        or not inside(root, resolved_source)
      then
        return vim.notify(
          ("%q leads outside the project (%s)"):format(subdir, root),
          vim.log.levels.ERROR,
          { title = "New " .. kind }
        )
      end

      header_dir, source_dir = resolved_header, resolved_source
    end

    local stem = conv.snake and to_snake(class) or class

    local header_path = vim.fs.joinpath(header_dir, stem .. conv.header_ext)
    local header_body, source_body = build(class, conv)
    -- `interface` and `template` return no source body -- both are header-only,
    -- for the reasons in their comments.
    local source_path = source_body and vim.fs.joinpath(source_dir, stem .. conv.source_ext) or nil

    -- Check both files before writing either, so a half-created class is not
    -- possible.
    for _, path in ipairs { header_path, source_path } do
      if vim.uv.fs_stat(path) then
        return vim.notify("Already exists: " .. path:sub(#root + 2), vim.log.levels.ERROR, { title = "New " .. kind })
      end
    end

    local open, close = guard(conv, class)
    local header = vim.list_extend(vim.deepcopy(open), header_body)
    vim.list_extend(header, close)

    vim.fn.mkdir(header_dir, "p")
    vim.fn.writefile(header, header_path)

    local added_to, not_added
    if source_path then
      vim.fn.mkdir(source_dir, "p")
      local source = { '#include "' .. include_spelling(root, header_path, source_dir) .. '"', "" }
      vim.list_extend(source, source_body)
      vim.fn.writefile(source, source_path)
      added_to, not_added = add_to_cmake(root, source_path)
    end

    -- The header is what you open: it is where the class is actually designed,
    -- and `<Leader>lw` is one key away from the .cpp when there is one.
    vim.cmd.edit(vim.fn.fnameescape(header_path))

    local created = { header_path:sub(#root + 2) }
    if source_path then table.insert(created, source_path:sub(#root + 2)) end
    local message = table.concat(created, "\n")
    local level = vim.log.levels.INFO
    if added_to then
      message = message .. "\nadded to CMake target `" .. added_to .. "`"
    elseif not_added == "nomatch" then
      message = message .. "\nnot added to CMakeLists: no target lists a source near it"
      level = vim.log.levels.WARN
    end
    vim.notify(message, level, { title = "New " .. kind .. " " .. class })
  end)
end

return M
