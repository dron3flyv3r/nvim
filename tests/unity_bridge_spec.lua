local diagnostics = require "user.integrations.unity.diagnostics"

local function same(actual, expected, label)
  assert(
    vim.deep_equal(actual, expected),
    ("%s: expected %s, got %s"):format(label, vim.inspect(expected), vim.inspect(actual))
  )
end

local root = "/tmp/does-not-need-to-exist"

---@param items table[]
---@return table counts
local function record(items) return diagnostics.record(root, { schema = 1, items = items }) end

-- Unity repeats the position and the severity inside the message text, which
-- the diagnostic already carries in its own fields. What is left is the part
-- worth reading in virtual text.
same(
  record {
    {
      file = "Assets/Foo.cs",
      line = 12,
      column = 5,
      severity = "error",
      message = "Assets/Foo.cs(12,5): error CS0103: The name 'bar' does not exist in the current context",
    },
  },
  { errors = 1, warnings = 0 },
  "one error"
)

same(diagnostics.list(), {
  {
    filename = root .. "/Assets/Foo.cs",
    lnum = 12,
    col = 5,
    type = "E",
    code = "CS0103",
    text = "The name 'bar' does not exist in the current context",
  },
}, "the code is split off the message")

-- The same file is compiled into more than one assembly, and Unity reports its
-- messages once for each -- the same error, several times over.
same(
  record {
    {
      file = "Assets/Foo.cs",
      line = 3,
      column = 1,
      severity = "error",
      message = "Assets/Foo.cs(3,1): error CS1002: ; expected",
    },
    {
      file = "Assets/Foo.cs",
      line = 3,
      column = 1,
      severity = "error",
      message = "Assets/Foo.cs(3,1): error CS1002: ; expected",
    },
  },
  { errors = 1, warnings = 0 },
  "duplicates across assemblies collapse"
)

-- Same file and code, different line: two separate things to fix.
same(
  record {
    {
      file = "Assets/Foo.cs",
      line = 3,
      column = 1,
      severity = "error",
      message = "Assets/Foo.cs(3,1): error CS1002: ; expected",
    },
    {
      file = "Assets/Foo.cs",
      line = 9,
      column = 1,
      severity = "error",
      message = "Assets/Foo.cs(9,1): error CS1002: ; expected",
    },
  },
  { errors = 2, warnings = 0 },
  "the same code on two lines is two diagnostics"
)

same(
  record {
    {
      file = "Assets/Baz.cs",
      line = 3,
      column = 1,
      severity = "warning",
      message = "Assets/Baz.cs(3,1): warning CS0168: unused",
    },
    {
      file = "Assets/Foo.cs",
      line = 1,
      column = 1,
      severity = "error",
      message = "Assets/Foo.cs(1,1): error CS0246: missing type",
    },
  },
  { errors = 1, warnings = 1 },
  "errors and warnings are counted apart"
)

-- Warnings are left out unless asked for: the usual question is what is
-- stopping the game from starting, and that is the errors.
same(#diagnostics.list(), 1, "the default list is errors only")
same(#diagnostics.list(true), 2, "warnings are included on request")

local list = diagnostics.list(true)
same({ list[1].filename, list[2].filename }, {
  root .. "/Assets/Baz.cs",
  root .. "/Assets/Foo.cs",
}, "the list is ordered by file")
same({ list[1].type, list[2].type }, { "W", "E" }, "severities survive the round trip")

-- A message the compiler wrote in some other shape still has to produce a
-- diagnostic; losing the error entirely is worse than losing its code.
same(
  record {
    { file = "Assets/Odd.cs", line = 1, column = 1, severity = "error", message = "something went wrong" },
  },
  { errors = 1, warnings = 0 },
  "an unparsed message is still an error"
)
same(diagnostics.list()[1].text, "something went wrong", "an unparsed message is kept whole")
same(diagnostics.list()[1].code, nil, "a message with no code carries none")

-- An absolute path is used as given, not glued onto the project root.
record {
  {
    file = "/opt/pkg/Thing.cs",
    line = 2,
    column = 2,
    severity = "error",
    message = "/opt/pkg/Thing.cs(2,2): error CS0001: x",
  },
}
same(diagnostics.list()[1].filename, "/opt/pkg/Thing.cs", "absolute paths are left alone")

same(record {}, { errors = 0, warnings = 0 }, "a clean compile clears the counts")
same(diagnostics.list(), {}, "a clean compile clears the list")

diagnostics.clear()

local companion = require "user.integrations.unity.companion"
same(companion.state_file "/p", "/p/Library/nvim-unity/state.json", "state file lives under Library")
same(companion.watch_dir "/p", "/p/Library/nvim-unity", "the watch is on the directory, not the file")
assert(not companion.installed "/p", "a project without the bridge is not reported as having it")
