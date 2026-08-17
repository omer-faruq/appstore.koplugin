-- appstore_mirror_test.lua
-- Run with: cd <extracted-koreader-dir> && ./luajit plugins/appstore.koplugin/tests/appstore_mirror_test.lua
--
-- Unlike the plugin_paths test this one also runs under a plain LuaJIT, as long
-- as the working directory is a KOReader tree: the two KOReader-only requires
-- are stubbed below, and socket/url.lua is picked up from common/.
package.path = "plugins/appstore.koplugin/?.lua;common/?.lua;" .. package.path

-- socket/url.lua requires the socket module only to hang itself off its table.
-- Where the C core behind it is not loadable (a plain LuaJIT rather than
-- KOReader's), an empty table serves url.lua just as well. Probing socket.core
-- rather than socket keeps the failure off the "socket" name itself, which
-- require would otherwise refuse to retry.
if not pcall(require, "socket.core") then
    package.preload["socket"] = function() return {} end
end

-- Stand-ins for the settings store and the gettext wrapper, so the test neither
-- touches a real settings file nor needs a translation catalog.
local store = {}
package.preload["appstore_settings"] = function()
    return {
        readSetting = function(_, key) return store[key] end,
        saveSetting = function(_, key, value) store[key] = value end,
        flush = function() end,
    }
end
package.preload["appstore_gettext"] = function()
    return setmetatable({}, { __call = function(_, msgid) return msgid end })
end

local config = {}
package.preload["appstore_configuration"] = function() return config end

local Mirror = require("appstore_mirror")

local failures = 0
local function check(label, got, expected)
    if got == expected then
        print("PASS", label)
    else
        failures = failures + 1
        print("FAIL", label, "expected=", tostring(expected), "got=", tostring(got))
    end
end

-- Each "restart" is a fresh module load against whatever the store and the
-- config table hold at that moment.
local function restart()
    package.loaded["appstore_mirror"] = nil
    package.loaded["appstore_configuration"] = nil
    Mirror = require("appstore_mirror")
end

-- ── Custom prefix validation ─────────────────────────────────────────────────
check("trailing slash added", Mirror.normalizeCustomUrl("https://gh-proxy.com"), "https://gh-proxy.com/")
check("http accepted (self-hosted mirrors)", Mirror.normalizeCustomUrl("http://192.168.1.10:8080/"), "http://192.168.1.10:8080/")
check("whitespace trimmed", Mirror.normalizeCustomUrl("  https://x.dev/  "), "https://x.dev/")
check("scheme required", Mirror.normalizeCustomUrl("gh-proxy.com"), nil)
check("only http(s)", Mirror.normalizeCustomUrl("ftp://x.dev/"), nil)
check("query string rejected", Mirror.normalizeCustomUrl("https://x.dev/?url="), nil)
check("credentials rejected", Mirror.normalizeCustomUrl("https://u:p@x.dev/"), nil)
check("out-of-range port rejected", Mirror.normalizeCustomUrl("https://x.dev:99999/"), nil)
check("empty rejected", Mirror.normalizeCustomUrl(""), nil)
check("non-string rejected", Mirror.normalizeCustomUrl(42), nil)

check("http is flagged insecure", Mirror.isInsecurePrefix("http://x.dev/"), true)
check("https is not", Mirror.isInsecurePrefix("https://x.dev/"), false)

-- ── Direct (the default): every URL passes through untouched ─────────────────
local RAW = "https://raw.githubusercontent.com/o/r/HEAD/README.md"
local ZIPBALL = "https://api.github.com/repos/o/r/zipball"
check("default preset is direct", Mirror.getCurrentPresetId(), "direct")
check("direct leaves raw URLs alone", Mirror.apply(RAW), RAW)
check("direct leaves zipball alone", Mirror.apply(ZIPBALL), ZIPBALL)

-- ── Prefixing ────────────────────────────────────────────────────────────────
check("custom preset stored", Mirror.setPreset("custom", "https://mirror.test/"), true)
check("custom preset active", Mirror.getCurrentPresetId(), "custom")
check("raw URL prefixed", Mirror.apply(RAW), "https://mirror.test/" .. RAW)
-- The API zipball endpoint is not something download mirrors serve; it is
-- rewritten to the archive URL they do.
check("zipball rewritten to archive", Mirror.apply(ZIPBALL),
    "https://mirror.test/https://github.com/o/r/archive/HEAD.zip")
check("zipball ref preserved", Mirror.apply("https://api.github.com/repos/o/r/zipball/v1.2.3"),
    "https://mirror.test/https://github.com/o/r/archive/v1.2.3.zip")
check("release asset prefixed", Mirror.apply("https://github.com/o/r/releases/download/v1/a.zip"),
    "https://mirror.test/https://github.com/o/r/releases/download/v1/a.zip")
check("already-prefixed URL left as is", Mirror.apply("https://mirror.test/" .. RAW),
    "https://mirror.test/" .. RAW)
check("nil passes through", Mirror.apply(nil), nil)
check("empty string passes through", Mirror.apply(""), "")

-- Only GitHub hosts are handed to the mirror.
check("foreign host untouched", Mirror.apply("https://example.com/x.zip"), "https://example.com/x.zip")
check("lookalike host untouched", Mirror.apply("https://github.com.evil.tld/x.zip"),
    "https://github.com.evil.tld/x.zip")
check("host match is case-insensitive", Mirror.apply("https://RAW.githubusercontent.com/o/r/HEAD/a"),
    "https://mirror.test/https://RAW.githubusercontent.com/o/r/HEAD/a")

-- ── Bad input is refused rather than stored ──────────────────────────────────
check("junk custom URL refused", Mirror.setPreset("custom", "not a url"), false)
check("unknown preset id refused", Mirror.setPreset("nope"), false)
store.download_mirror_custom_url = "garbage"
check("unusable stored URL falls back to direct", Mirror.getCurrentPresetId(), "direct")
check("fallback means no prefixing", Mirror.apply(RAW), RAW)

-- ── Presets ──────────────────────────────────────────────────────────────────
store.download_mirror_custom_url = nil
check("preset selected", Mirror.setPreset("gh_proxy_com"), true)
check("preset prefix applied", Mirror.apply(RAW), "https://gh-proxy.com/" .. RAW)
check("preset label", Mirror.getCurrentLabel(), "gh-proxy.com")
check("back to direct", Mirror.setPreset("direct"), true)
check("direct again", Mirror.apply(RAW), RAW)

-- ── Config file vs. UI: whichever was touched last wins ──────────────────────
store, config = {}, {}
restart()
check("no config, no setting -> direct", Mirror.getCurrentPresetId(), "direct")
check("absent config writes nothing", next(store), nil)

Mirror.setPreset("ghproxy_net")
restart()
check("UI choice survives a restart", Mirror.getCurrentPresetId(), "ghproxy_net")

store, config = {}, { download_mirror_preset = "gh_proxy_com" }
restart()
check("config applies when first seen", Mirror.getCurrentPresetId(), "gh_proxy_com")

Mirror.setPreset("direct")
restart()
check("UI overrides an unchanged config", Mirror.getCurrentPresetId(), "direct")

config = { download_mirror_preset = "gh_ddlc_top" }
restart()
check("edited config wins again", Mirror.getCurrentPresetId(), "gh_ddlc_top")

config = {}
restart()
check("removed config restores the default", Mirror.getCurrentPresetId(), "direct")
restart()
check("removal is not re-applied", Mirror.getCurrentPresetId(), "direct")

store, config = {}, { download_mirror_prefix = "https://cfg.test" }
restart()
check("bare prefix implies the custom preset", Mirror.getCurrentPresetId(), "custom")
check("config prefix normalized on the way in", Mirror.getCustomUrl(), "https://cfg.test/")
check("config prefix used", Mirror.apply(RAW), "https://cfg.test/" .. RAW)

Mirror.setPreset("custom", "https://ui.test/")
restart()
check("UI prefix overrides an unchanged config", Mirror.getCustomUrl(), "https://ui.test/")

config = { download_mirror_prefix = "not a url" }
restart()
check("unusable config prefix clears the setting", Mirror.getCustomUrl(), "")
check("unusable config prefix -> direct", Mirror.getCurrentPresetId(), "direct")
Mirror.setPreset("custom", "https://ui2.test/")
restart()
check("unusable config prefix not re-applied", Mirror.getCustomUrl(), "https://ui2.test/")

print(failures == 0 and "ALL PASS" or (failures .. " FAILURE(S)"))
os.exit(failures == 0 and 0 or 1)
