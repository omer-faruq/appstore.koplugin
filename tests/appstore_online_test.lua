-- appstore_online_test.lua
-- Run with a plain LuaJIT, from the plugin folder or from a KOReader tree:
--   luajit tests/appstore_online_test.lua
--   ./luajit plugins/appstore.koplugin/tests/appstore_online_test.lua
--
-- KOReader's NetworkMgr:runWhenOnline drops its callback without a word when
-- Wi-Fi is connected but hostnames do not resolve. These check that the
-- wrapper says so instead, and otherwise leaves KOReader's handling alone.
package.path = "plugins/appstore.koplugin/?.lua;./?.lua;" .. package.path

local Online = require("appstore_online")

local failures = 0
local function check(label, got, expected)
    if got == expected then
        print("PASS", label)
    else
        failures = failures + 1
        print("FAIL", label, "expected=", tostring(expected), "got=", tostring(got))
    end
end

-- A NetworkMgr stand-in: `online` and `connected` are what it reports, and
-- runWhenOnline only records that it was handed the callback.
local function fakeNet(online, connected)
    local net = { handed = 0 }
    function net:isOnline() return online end
    function net:isConnected() return connected end
    function net:runWhenOnline(callback)
        self.handed = self.handed + 1
        self.callback = callback
    end
    return net
end

-- Counts live in a table: the callback can run later, after attempt() returned.
local function attempt(net)
    local seen = { ran = 0, unreachable = 0 }
    Online.run(net, function() seen.ran = seen.ran + 1 end,
        function() seen.unreachable = seen.unreachable + 1 end)
    return seen
end

do
    local net = fakeNet(true, true)
    local seen = attempt(net)
    check("online: runs the callback", seen.ran, 1)
    check("online: not reported unreachable", seen.unreachable, 0)
    check("online: no second check through KOReader", net.handed, 0)
end

do
    local net = fakeNet(false, true)
    local seen = attempt(net)
    check("connected without internet: callback not run", seen.ran, 0)
    check("connected without internet: reported unreachable", seen.unreachable, 1)
    check("connected without internet: not handed to KOReader to drop", net.handed, 0)
end

do
    local net = fakeNet(false, false)
    local seen = attempt(net)
    check("Wi-Fi off: left to KOReader to turn on", net.handed, 1)
    check("Wi-Fi off: not reported unreachable", seen.unreachable, 0)
    check("Wi-Fi off: callback not run yet", seen.ran, 0)
    net.callback()
    check("Wi-Fi off: KOReader runs the same callback once connected", seen.ran, 1)
end

do
    -- No unreachable handler: nothing to call, and no error.
    local ok = pcall(Online.run, fakeNet(false, true), function() end)
    check("connected without internet, no handler: no error", ok, true)
end

if failures > 0 then
    print(failures .. " FAILED")
    os.exit(1)
end
print("all passed")
