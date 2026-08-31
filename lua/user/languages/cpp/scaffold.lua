-- Creating a C++ class: the two files, the include between them, and the line
-- in CMakeLists that makes the second one get compiled.
--
-- WHY THIS IS NOT A SNIPPET: a snippet expands inside a buffer that already
-- exists, and the tedious half of "new class" happens before there is a buffer
-- -- deciding the file name, deciding which directory, creating a *pair* of
-- files that have to agree about the include, and telling the build system the
-- .cpp is there. `blink.cmp` and `snippets/` cover the inside-a-file half
-- perfectly well; this covers the rest.
--
-- WHY IT DETECTS RATHER THAN IMPOSES: there are two established C++ house
-- styles in this user's own code and they disagree about nearly everything.
--
--     ~/code/SOPA-ESP32-MK3   flat directory, snake_case pairs
--                             (settings_store.h / settings_store.cpp),
--                             `#pragma once`, no namespace, no CMakeLists
--     ~/code/evlo-sim-mk1     src/, C++20, CMake with an explicit source list
--                             (`add_executable(app src/main.cpp)`)
--
-- A scaffolder with a hardcoded style is wrong in one of those projects and
-- annoying in both, so every decision below -- file name case, header
-- extension, guard style, namespace, target directory -- is read off the files
-- that are already there. The defaults only apply to an empty project.
--
-- WHERE THE FILES GO: beside the buffer you are in, unless you say otherwise.
-- The prompt takes a path as well as a name -- `audio/mixer` creates the pair in
-- an `audio/` subdirectory of wherever the plain name would have gone, creating
-- it if it is not there yet, and `/src/audio/mixer` is the same thing measured
-- from the project root instead. Everything downstream (the include between the
-- files, the path written into CMakeLists) follows from the real paths, so a
-- subdirectory needs no special handling in any of it.
--
-- WHAT IT DELIBERATELY DOES NOT DO: overwrite. If either file exists the whole
-- operation stops before writing anything; there is no merge, no backup and no
-- prompt, because the cost of getting that wrong is somebody's afternoon.

local M = {}

--- Directories that are never this project's own source.
---
--- `external/` matters most: evlo-sim-mk1 vendors all of Dear ImGui there, and
--- imgui's ~30 lowercase headers would otherwise outvote the handful of files
--- the project actually wrote when the naming convention is counted.
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

--- `audio_mixer` -> `AudioMixer`, but `AudioMixer` -> `AudioMixer`.
---
--- The asymmetry is deliberate and comes from the SOPA code: file names there
--- are snake_case (`settings_store.h`) while the types inside them are
--- PascalCase (`struct DeviceSettings`). So a lowercase name typed at the
--- prompt is a *file* name being spelled out and wants converting, whereas
--- anything with a capital in it is already a type name and must be left
--- exactly as written -- `HTTPServer` has to survive.
---@param name string
---@return string
local function to_pascal(name)
  if name:find "%u" then return name end
  local pascal = name:gsub("(%a)([%w]*)", function(head, tail) return head:upper() .. tail end)
  return (pascal:gsub("[_%-%s]", ""))
end

--- `AudioMixer` -> `audio_mixer`, `HTTPServer` -> `http_server`.
---
--- Two passes because one does not handle runs of capitals: the first splits
--- `oM` in `audioMixer`, the second splits `PSe` in `HTTPServer` so the break
--- lands before the last capital of the run rather than after it.
---@param name string
---@return string
local function to_snake(name)
  local snake = name:gsub("(%l)(%u)", "%1_%2")
  snake = snake:gsub("(%u)(%u%l)", "%1_%2")
  snake = snake:gsub("[%-%s]+", "_")
  return (snake:lower())
end

--- Header files belonging to the project itself, for the conventions to be
--- read off.
---
--- Only four directories, each two levels deep, rather than a walk of the
--- whole tree: the convention is visible in the first dozen files and a
--- recursive scan of a repo with a vendored dependency in it is both slow and
--- -- per `SKIP_DIRS` above -- misleading. The buffer's own directory comes
--- first because in a project with several conventions the local one wins.
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
    if count > best_ns_count then best_ns, best_ns_count = ns, count end
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

--- Where the header and the source belong.
---
--- The rule that does the work is "beside the file you are looking at", which
--- is correct in both of this user's projects without either of them being a
--- special case: editing `ui_root.cpp` in SOPA's flat directory puts the new
--- pair in that directory, and editing `src/main.cpp` in evlo puts it in
--- `src/`. The `include/` branch is for the third layout -- the one where
--- public headers are installed -- which is common enough in other people's
--- CMake projects to be worth handling even though neither project here uses
--- it.
---
--- This is only the *base*: a path typed at the prompt (`audio/mixer`) is
--- appended to both of the directories returned here, so the include layout
--- keeps mirroring -- `include/<project>/audio/` and `src/audio/` -- instead of
--- flattening the header back out beside its siblings.
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

--- The path the .cpp should `#include`, as written between the quotes.
---
--- Beside each other this is just the file name. Under `include/` it has to be
--- the path relative to the include root, or the compiler will not find it
--- from another directory -- `#include "audio_mixer.h"` next to
--- `include/evlo/audio_mixer.h` compiles only by accident, from files that
--- happen to sit in the same directory.
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

--- Split `audio/mixer` into the subdirectory and the name.
---
--- The last slash is the separator, because a class name cannot contain one --
--- everything before it is a path and the remainder is the identifier. A
--- leading slash means "from the project root" rather than "from here", which
--- is the escape hatch for the case the buffer's directory gets wrong.
---@param input string
---@return string? subdir  nil when no slash was typed at all
---@return string name
---@return boolean from_root
local function split_path(input)
  local dir, name = input:match "^(.*)/([^/]*)$"
  if not dir then return nil, input, false end
  return (dir:gsub("^/+", "")), name, vim.startswith(dir, "/")
end

--- Resolve `.` and `..` textually, for an absolute path.
---
--- Not `vim.fs.normalize`: which of these it collapses has changed across
--- Neovim versions, and the whole point of doing it here is to be able to check
--- the answer against the project root afterwards -- `../../etc/foo` has to come
--- out as a path that fails that check, not as one that quietly did not resolve.
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

--- The three shapes this can create.
---
--- Each returns the header body and, for `class`, the source body. They are
--- deliberately close to empty: the point is to get past the boilerplate that
--- has one correct answer (the guard, the include, the `Class::` qualification)
--- and stop before the part that does not (what the class actually does).
--- clang-format runs on save and will re-indent all of it to the project's
--- `.clang-format`, so the spacing here only has to be legible.
---@type table<string, fun(class: string, conv: CppConventions): string[], string[]?>
local TEMPLATES = {
  --- A class with an out-of-line default constructor.
  ---
  --- The constructor is there to give the .cpp a reason to exist and something
  --- to pattern-match on -- it is the one line that demonstrates the
  --- `AudioMixer::AudioMixer()` form you then copy for every other method. No
  --- destructor: declaring one you do not need suppresses the implicit move
  --- operations, which is the rule-of-zero trap, and `<Leader>lcm` declares the
  --- whole set properly on the day you do need them.
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

  --- A pure-virtual base: the thing other classes inherit from.
  ---
  --- Header-only, because there is nothing to put in a .cpp. The virtual
  --- destructor is the entire reason this is a separate template rather than a
  --- comment on the class one -- deleting a derived object through a base
  --- pointer without it is undefined behaviour, it is silent, and it is the
  --- single most common bug in hand-written C++ interfaces. `= default` rather
  --- than `{}` so the move operations are not suppressed.
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

  --- A class template.
  ---
  --- Header-only and not negotiable about it: a template is not code until it
  --- is instantiated, so the definitions have to be visible at every use site.
  --- Splitting one across a .h and a .cpp produces link errors, not compile
  --- errors, which is why this template exists separately from `class` --
  --- creating the .cpp at all would be the mistake.
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

--- Add `rel_path` to the source list of the CMake target that already compiles
--- something from the same directory.
---
--- WHAT IT LOOKS FOR is a target whose list already mentions a file in the new
--- file's directory -- that is the evidence that this is where sources for that
--- target go. `add_executable(app src/main.cpp)` plus a new `src/audio_mixer.cpp`
--- is a match; a target that only lists files from `external/` is not, and gets
--- left alone rather than guessed at.
---
--- IF NOTHING COMPILES THAT DIRECTORY it walks up. A path typed at the prompt
--- can name a directory that did not exist a second ago, so there is nothing in
--- it for any target to already list, and the exact-match rule alone would leave
--- every new subdirectory out of the build -- which fails at link time, long
--- after the mistake. `src/audio/mixer.cpp` in a project whose only target lists
--- `src/main.cpp` joins that target. The walk stops at the project root, so it
--- can pick the wrong target in a project with several; that is visible in the
--- notification and one undo away, which the missing symbol is not.
---
--- WHAT IT REFUSES: a source list that is not a literal list -- a `GLOB`
--- anywhere in the file, or a target whose sources are a `${VAR}`. Those
--- projects collect their sources indirectly and need no edit at all; writing
--- the path in would be duplicate, not helpful. Returning nil here is a success,
--- not a failure, and is reported differently from having found nothing.
---
--- WHY TEXT AND NOT TREESITTER: the cmake parser is not in this config's
--- `ensure_installed`, so requiring it would make this silently do nothing on a
--- machine that has not downloaded it. The shapes being matched are two
--- keywords and a balanced paren, which is inside what a text scan does
--- reliably.
---
--- NOTE there is no regenerate afterwards. CMake does not need one: Ninja
--- writes a rule that re-runs cmake whenever `CMakeLists.txt` is newer than the
--- cache, so the next contextual build picks the new source up on its own.
---@param root string
---@param source_path string
---@return string? target the target the file was added to, nil if nothing was written
---@return "none"|"indirect"|"nomatch"|nil why nothing was written
local function add_to_cmake(root, source_path)
  local cmake_path = vim.fs.joinpath(root, "CMakeLists.txt")
  if not vim.uv.fs_stat(cmake_path) then return nil, "none" end

  local ok, lines = pcall(vim.fn.readfile, cmake_path)
  if not ok or type(lines) ~= "table" then return nil, "none" end

  -- Whether this project's sources reach the target by some route other than a
  -- literal list, so a project that needs no edit can be told apart from one
  -- where the edit was wanted and did not happen. `file(GLOB ...)` is matched
  -- across the whole file rather than inside a target block, because that is
  -- where it is written -- the glob fills a variable several lines above the
  -- `add_executable` that uses it.
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

        -- `add_executable(app ${SRC})`: the sources are a variable, so there is
        -- no list to sort a path into and nothing is missing from the build.
        -- Everything after the target's own name counts, since the target may
        -- itself be spelled `${NAME}`.
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
          -- Where the new path sorts among the entries this block already lists
          -- from the same directory. `first_after` is the first entry that sorts
          -- after it (insert above that one); `last_same` is the last entry from
          -- the directory at all (insert below that one, when the new file sorts
          -- last). If neither is set this block compiles nothing from that
          -- directory and is not ours to edit.
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
      -- A root-relative path is taken literally and puts both files in the one
      -- directory named. Splitting it across `include/` would mean guessing
      -- which half of `/src/audio` the user meant, and the reason to type the
      -- root-relative form in the first place is to stop the guessing.
      local base_header, base_source = header_dir, source_dir
      if from_root then base_header, base_source = root, root end

      local resolved_header = collapse(vim.fs.joinpath(base_header, subdir))
      local resolved_source = collapse(vim.fs.joinpath(base_source, subdir))

      -- `..` is allowed -- `../dsp/filter` from `src/audio` is a reasonable
      -- thing to type -- but only as far as the project root. Beyond that the
      -- CMake edit, the include spelling and the paths in the notification are
      -- all meaningless, so it is refused rather than half-supported.
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
        return vim.notify(
          "Already exists: " .. path:sub(#root + 2),
          vim.log.levels.ERROR,
          { title = "New " .. kind }
        )
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
      -- Nothing in the file compiles this directory or any directory above it,
      -- so there was no list to sort the path into. Said out loud because the
      -- alternative is a file that compiles fine on its own and is simply never
      -- linked, which shows up much later as a missing symbol.
      message = message .. "\nnot added to CMakeLists: no target lists a source near it"
      level = vim.log.levels.WARN
    end
    vim.notify(message, level, { title = "New " .. kind .. " " .. class })
  end)
end

return M
