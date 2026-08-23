-- appstore_dir_collision_test.lua
-- Regression test for the directory-collision guard that prevents a
-- misidentified archive from silently overwriting an unrelated plugin.
--
-- This guards against the exact bug from PR #32: a leaked pending_install_context
-- (or the detection fallback) pointing an install at the wrong directory. The
-- decision logic in appstore_install_helpers is pure, so we can test it without
-- the full AppStore runtime.
--
-- Run with: cd <extracted-koreader-dir> && ./luajit plugins/appstore.koplugin/tests/appstore_dir_collision_test.lua
package.path = "plugins/appstore.koplugin/?.lua;" .. package.path

local H = require("appstore_install_helpers")

local failures = 0
local function check(label, got, expected)
    local ok
    if type(expected) == "table" then
        ok = type(got) == "table" and #got == #expected
        if ok then
            for i = 1, #expected do
                if got[i] ~= expected[i] then ok = false end
            end
        end
    else
        ok = got == expected
    end
    if ok then
        print("PASS", label)
    else
        failures = failures + 1
        print("FAIL", label, "expected=", tostring(expected), "got=", tostring(got))
    end
end

-- normalizePluginKey: case + punctuation insensitive.
check("normalize: lowercase+strip",
    H.normalizePluginKey("Markdown Reader"),
    H.normalizePluginKey("markdownreader"))

-- Same plugin -> safe (nil)
check("same plugin by name -> nil",
    H.decideCollision("markdownreader", "markdownreader.koplugin", "markdownreader"), nil)
check("same plugin, dir base matches, name unknown -> nil",
    H.decideCollision("markdownreader", "markdownreader.koplugin", ""), nil)
-- The archive detector's loose regex can capture a `fullname` (e.g.
-- "Markdown Reader") instead of the real `name` ("markdownreader"). We must
-- NOT refuse a legitimate update because of that. This is the false-positive
-- Opus flagged in the PR review.
check("same plugin, fullname captured as name -> nil (no false positive)",
    H.decideCollision("markdownreader", "markdownreader.koplugin", "Markdown Reader"), nil)

-- Different plugin -> occupied_by_other
check("different plugin -> occupied_by_other",
    H.decideCollision("appstore", "appstore.koplugin", "markdownreader"), "occupied_by_other")
-- The original guard disabled itself whenever the installed plugin's _meta.name
-- matched its own folder basename (true for virtually every well-formed plugin,
-- including AppStore). The new logic must NOT do that.
check("appstore dir vs markdownreader archive -> occupied_by_other (guard must fire)",
    H.decideCollision("appstore", "appstore.koplugin", "markdownreader"), "occupied_by_other")

-- Name unknown but directory basename differs from the installed plugin ->
-- unknown_name_clash (we cannot confirm it is the same plugin, so refuse).
check("different plugin, name unknown, dir base differs -> unknown_name_clash",
    H.decideCollision("Bar", "foo.koplugin", ""), "unknown_name_clash")
-- Name unknown but everything is consistent (well-formed, same-named plugin) ->
-- safe (allows a reinstall of a fullname-only plugin).
check("name unknown, well-formed same-name -> nil",
    H.decideCollision("foo", "foo.koplugin", ""), nil)

-- Unreadable / missing name from the existing _meta.lua -> unreadable_meta
-- (the caller distinguishes a truly-absent file from an unreadable one).
check("nil existing name -> unreadable_meta",
    H.decideCollision(nil, "x.koplugin", "x"), "unreadable_meta")
check("empty existing name -> unreadable_meta",
    H.decideCollision("", "x.koplugin", "x"), "unreadable_meta")

if failures == 0 then
    print("ALL TESTS PASSED")
    os.exit(0)
else
    print(string.format("%d TEST(S) FAILED", failures))
    os.exit(1)
end
