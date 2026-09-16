local cargo = require "user.languages.rust.cargo"

local function same(actual, expected, label)
  assert(
    vim.deep_equal(actual, expected),
    ("%s: expected %s, got %s"):format(label, vim.inspect(expected), vim.inspect(actual))
  )
end

-- A two-member workspace shaped like a `hot-lib-reloader` game: a host binary
-- that owns the window, and the dylib it reloads.
local METADATA = vim.json.encode {
  workspace_root = "/tmp/game",
  target_directory = "/tmp/game/target",
  workspace_members = { "host 0.1.0 (path+file:///tmp/game/host)", "logic 0.1.0 (path+file:///tmp/game/logic)" },
  packages = {
    {
      id = "logic 0.1.0 (path+file:///tmp/game/logic)",
      name = "logic",
      manifest_path = "/tmp/game/logic/Cargo.toml",
      targets = { { name = "logic", kind = { "cdylib" } } },
      dependencies = { { name = "raylib" } },
    },
    {
      id = "host 0.1.0 (path+file:///tmp/game/host)",
      name = "host",
      manifest_path = "/tmp/game/host/Cargo.toml",
      targets = { { name = "host", kind = { "bin" } }, { name = "bench", kind = { "example" } } },
      dependencies = { { name = "hot-lib-reloader" }, { name = "raylib" } },
    },
    {
      -- Not a member: must not survive parsing.
      id = "raylib 5.0.0 (registry+https://github.com/rust-lang/crates.io-index)",
      name = "raylib",
      manifest_path = "/registry/raylib/Cargo.toml",
      targets = { { name = "raylib", kind = { "lib" } } },
      dependencies = {},
    },
  },
}

local workspace = assert(cargo.parse_metadata(METADATA))

same(workspace.root, "/tmp/game", "workspace root")
same(workspace.target_dir, "/tmp/game/target", "target directory")
same(
  vim.tbl_map(function(pkg) return pkg.name end, workspace.packages),
  { "host", "logic" },
  "workspace members only, sorted"
)

same(cargo.targets(cargo.package(workspace, "host"), "bin"), { "host" }, "binary targets")
same(cargo.targets(cargo.package(workspace, "host"), "example"), { "bench" }, "example targets")
same(cargo.targets(cargo.package(workspace, "logic"), "bin"), {}, "a cdylib has no binaries")

-- The dylib is the thing worth rebuilding, not the host that reloads it.
same(cargo.hot_reload_lib(workspace).name, "logic", "hot reload library detection")

local plain = assert(cargo.parse_metadata(vim.json.encode {
  workspace_root = "/tmp/cli",
  target_directory = "/tmp/cli/target",
  workspace_members = { "cli 0.1.0 (path+file:///tmp/cli)" },
  packages = {
    {
      id = "cli 0.1.0 (path+file:///tmp/cli)",
      name = "cli",
      manifest_path = "/tmp/cli/Cargo.toml",
      targets = { { name = "cli", kind = { "bin" } } },
      dependencies = { { name = "clap" } },
    },
  },
}))
same(cargo.hot_reload_lib(plain), nil, "a plain binary crate is not hot reloadable")

same(
  cargo.build_args {
    package = "logic",
    profile = "dev",
    features = { "devtools", "trace" },
  },
  { "build", "--package", "logic", "--features", "devtools,trace" },
  "build args for the dylib"
)

same(
  cargo.build_args {
    package = "host",
    target = "host",
    target_kind = "bin",
    profile = "release",
    features = {},
  },
  { "build", "--package", "host", "--bin", "host", "--release" },
  "build args for a release binary"
)

same(cargo.build_args { profile = "dev", features = {} }, { "build" }, "build args with nothing set")

same(
  cargo.executable(workspace, { package = "host", target = "host", target_kind = "bin", profile = "dev" }),
  "/tmp/game/target/debug/host",
  "debug binary path"
)
same(
  cargo.executable(workspace, { package = "host", target = "host", target_kind = "bin", profile = "release" }),
  "/tmp/game/target/release/host",
  "release binary path"
)
same(
  cargo.executable(workspace, { package = "host", target = "bench", target_kind = "example", profile = "dev" }),
  "/tmp/game/target/debug/examples/bench",
  "example binary path"
)
-- With no target named, the package's single binary is unambiguous.
same(
  cargo.executable(workspace, { package = "host", target = "", target_kind = "bin", profile = "dev" }),
  "/tmp/game/target/debug/host",
  "binary inferred from the package"
)
-- A cdylib has no binary, and guessing one would launch nothing.
same(
  cargo.executable(workspace, { package = "logic", target = "", target_kind = "bin", profile = "dev" }),
  nil,
  "no binary to infer"
)

same(
  cargo.parse_env { "RUST_LOG=debug", "RUST_BACKTRACE=1", "  SPACED = yes  ", "nonsense", "" },
  { RUST_LOG = "debug", RUST_BACKTRACE = "1", SPACED = "yes" },
  "environment parsing skips malformed entries"
)
same(cargo.parse_env {}, nil, "no environment is nil, not an empty table")
same(cargo.parse_env(nil), nil, "a missing environment is nil")

same(select(2, cargo.parse_metadata "not json") ~= nil, true, "invalid JSON is an error, not a crash")
same(select(2, cargo.parse_metadata "{}") ~= nil, true, "JSON without a workspace root is an error")

-- Defaults follow the shape of the project: a hot-reload workspace rebuilds
-- the dylib and restarts nothing, a plain crate relaunches its binary.
local watch = require "user.languages.rust.watch"

local game = watch.defaults(workspace)
same(game.mode, "build", "hot reload workspaces default to rebuild only")
same(game.package, "logic", "and to building the dylib")

local cli = watch.defaults(plain)
same(cli.mode, "run", "plain workspaces default to relaunching")
same(cli.package, "cli", "on their only package")
same(cli.target, "cli", "naming the only binary explicitly")

-- Every default has to survive the form it is handed to, or the first
-- `:RustWatchConfigure` opens onto fields it refuses to submit.
local schema = watch.schema(workspace)
for name in pairs(game) do
  assert(schema[name], ("default %s has no matching form parameter"):format(name))
end

-- Overseer is lazy-loaded, so this half only runs when it happens to be there.
local has_form, form_utils = pcall(require, "overseer.form.utils")
if has_form then
  form_utils.validate_params(schema)
  for name, value in pairs(game) do
    assert(
      form_utils.validate_field(schema[name], value),
      ("default %s = %s is rejected by the form"):format(name, vim.inspect(value))
    )
  end
end
