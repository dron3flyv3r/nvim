local device = require "user.integrations.unity.android.device"
local player = require "user.integrations.unity.android.player"

local function same(actual, expected, label)
  assert(
    vim.deep_equal(actual, expected),
    ("%s: expected %s, got %s"):format(label, vim.inspect(expected), vim.inspect(actual))
  )
end

-- Unity's own shape: a per-platform map under a named key, with the next
-- setting at the same indentation as the key.
local settings = table.concat({
  "PlayerSettings:",
  "  applicationIdentifier:",
  "    Android: com.example.game",
  "    Standalone: com.example.desktop",
  "  buildNumber:",
  "    Standalone: 0",
  "  scriptingBackend:",
  "    Android: 1",
  "  il2cppCompilerConfiguration: {}",
}, "\n")

same(player.parse_setting(settings, "applicationIdentifier", "Android"), "com.example.game", "the android app id")
same(player.parse_setting(settings, "buildNumber", "Standalone"), "0", "a value from a later block")

-- The block ends at the next key on the key's own indentation. Without that,
-- a platform missing from one block is answered from the block below it.
same(player.parse_setting(settings, "buildNumber", "Android"), nil, "a platform the block does not list")
same(player.parse_setting(settings, "nothingLikeThis", "Android"), nil, "a key that is not there")

same(player.parse_backend(settings), "il2cpp", "ScriptingImplementation 1 is IL2CPP")
same(player.parse_backend(settings:gsub("Android: 1", "Android: 0")), "mono", "0 is Mono2x")
-- Absent means Unity's per-platform default applies, which cannot be read from
-- here -- so the answer is "unknown", never a guess.
same(player.parse_backend "PlayerSettings:\n  buildNumber:\n    Standalone: 0", nil, "no backend recorded")

same(
  player.parse_banner(
    "I Unity : Built from '6000.3/staging' branch, Version '6000.3.14f1 (d68c3f99a318)', "
      .. "Build type 'Development', Scripting Backend 'il2cpp', CPU 'arm64-v8a', Stripping 'Enabled'"
  ),
  {
    version = "6000.3.14f1 (d68c3f99a318)",
    build_type = "Development",
    backend = "il2cpp",
    stripping = "Enabled",
  },
  "the startup banner"
)

same(player.parse_banner "nothing of the sort", nil, "no banner in the buffer")
same(player.parse_debugger_port "D Unity : Starting managed debugger on port 56655", 56655, "the announced port")
same(player.parse_debugger_port "D Unity : Starting something else", nil, "no announcement")

-- `/proc/<pid>/net/tcp` is the whole network namespace, so the uid column is
-- what separates this app's listeners from every other app's. `0A` is LISTEN;
-- both columns are hex.
local net_tcp = table.concat({
  "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode",
  "   0: 00000000:1E67 00000000:0000 0A 00000000:00000000 00:00000000 00000000 10373 0 41266000 1",
  "   1: 00000000:DD4F 00000000:0000 0A 00000000:00000000 00:00000000 00000000 10373 0 41266001 1",
  "   2: 00000000:DD50 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000 0 41266002 1",
  "   3: 00000000:DD51 00000000:0000 01 00000000:00000000 00:00000000 00000000 10373 0 41266003 1",
}, "\n")

-- 1E67 is out of Unity's range, DD50 belongs to another uid, and DD51 is an
-- established connection rather than a listener.
same(player.parse_listening(net_tcp, 10373), { 56655 }, "only the app's listening debugger port")
same(player.parse_listening(net_tcp, 99999), {}, "a uid that owns nothing")

same(
  device.parse_device "R52Y80FMBPL  device usb:3-6 product:gtact5proxeea model:SM_X356B device:gtact5pro",
  { serial = "R52Y80FMBPL", state = "device", model = "SM_X356B" },
  "a connected device"
)
-- The one that matters: it has to survive to somewhere it can be reported,
-- because otherwise it is indistinguishable from no device at all.
same(
  device.parse_device "R52Y80FMBPL  unauthorized",
  { serial = "R52Y80FMBPL", state = "unauthorized", model = nil },
  "a device awaiting the on-screen prompt"
)

local logcat = require "user.integrations.unity.android.logcat"

-- `-v time`, exactly as the device writes it. The date is today's and the pid
-- does not change, so neither survives into the pane; the clock does.
local text, severity = logcat.parse_line "09-18 11:04:21.427 D/Unity   (13324): Starting managed debugger on port 56655"
same(text, "11:04:21 D Unity      Starting managed debugger on port 56655", "a formatted log line")
same(severity, "D", "the severity is carried out for highlighting")

-- logcat's own banners have no header at all, and dropping them would lose the
-- only marker of where one run ends and the next begins.
same({ logcat.parse_line "--------- beginning of system" }, { "--------- beginning of system", nil }, "a bare line")

same({ logcat.parse_frame "E Unity   : Foo:Update () (at Assets/Scripts/Foo.cs:42)" }, {
  "Assets/Scripts/Foo.cs",
  42,
}, "Unity's own stack frame format")

same({ logcat.parse_frame "  at Foo.Bar.Update () [0x00000] in /home/me/proj/Assets/Foo.cs:17" }, {
  "/home/me/proj/Assets/Foo.cs",
  17,
}, "Mono's stack frame format")

-- IL2CPP writes this where the path would be when the build carries no line
-- table. Jumping to a file called `<filename unknown>` helps nobody.
same({ logcat.parse_frame "  at Foo.Bar.Update () [0x00000] in <filename unknown>:0" }, {}, "a frame with no source")
same({ logcat.parse_frame "I Unity   : just a message" }, {}, "a line with no frame")
