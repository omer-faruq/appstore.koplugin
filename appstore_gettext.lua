--[[--
Self-contained localization for the App Store plugin.

KOReader's gettext singleton (`require("gettext")`) only loads the core
`l10n/koreader.mo` catalog, so strings that live inside a standalone plugin such
as this one are never translated by it. This module is a drop-in replacement for
`require("gettext")`: it reuses the core GetText for language detection, plural
handling and RTL wrapping, but resolves each msgid against a plugin-bundled
translation table first (`l10n/<lang>.lua`).

Usage is identical to gettext, so existing call sites need only swap the require:

    local _ = require("appstore_gettext")
    local label = _("Install")

Translation tables are plain Lua files returning `{ ["English source"] = "…" }`,
which keeps them editable and testable with plain LuaJIT (no msgfmt / .mo step).
Add a new language by dropping `l10n/<code>.lua` next to this file, where
`<code>` matches KOReader's locale code (e.g. `tr`, `de`, `pt_BR`, `zh_CN`).
--]]

local GetText = require("gettext")
local logger = require("logger")

-- Absolute directory holding this file, so the bundled l10n/ tables are found
-- regardless of where the plugin is installed.
local function thisDir()
    local source = debug.getinfo(1, "S").source
    -- source looks like "@C:\path\to\appstore.koplugin\appstore_gettext.lua"
    return source:match("^@(.*)[/\\][^/\\]+$")
end

local function loadLangTable(lang)
    -- "C" / nil / any en_* locale means "no translation, use source strings".
    if not lang or lang == "" or lang == "C" or lang:match("^en") then
        return nil
    end
    local dir = thisDir()
    if not dir then
        return nil
    end

    local function tryCode(code)
        local path = dir .. "/l10n/" .. code .. ".lua"
        local chunk = loadfile(path)
        if not chunk then
            return nil
        end
        local ok, tbl = pcall(chunk)
        if ok and type(tbl) == "table" then
            return tbl
        end
        logger.warn("appstore_gettext: failed to load", path, tbl)
        return nil
    end

    -- Exact locale first (e.g. pt_BR, zh_CN), then the base language (pt, zh)
    -- as a fallback so a generic file still applies to regional variants.
    local tbl = tryCode(lang)
    if not tbl then
        local base = lang:match("^(%a%a)")
        if base and base ~= lang then
            tbl = tryCode(base)
        end
    end
    return tbl
end

local translation = loadLangTable(GetText.current_lang) or {}

-- Callable table: `_(msgid)` returns the plugin translation when present,
-- otherwise delegates to the core gettext (which handles RTL wrapping and any
-- string that happens to be shared with KOReader's own catalog).
-- Reads such as `_.pgettext` / `_.current_lang` fall through to core GetText.
local AppStoreGetText = setmetatable({}, {
    __call = function(_self, msgid)
        return translation[msgid] or GetText(msgid)
    end,
    __index = GetText,
})

return AppStoreGetText
