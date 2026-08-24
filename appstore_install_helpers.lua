-- appstore_install_helpers.lua
--
-- Pure, side-effect-free helpers for safe plugin installation. Kept separate
-- from main.lua so they can be unit-tested without the full AppStore runtime
-- (see tests/appstore_dir_collision_test.lua).
--
-- These functions only do string comparison and normalization; they never
-- touch the filesystem or the UI, so a test can exercise the exact decision
-- logic that guards against silently overwriting an unrelated plugin.

local AppStoreInstallHelpers = {}

-- Normalize a plugin name into a comparator key: lowercase, alphanumerics only.
-- This lets us treat "Markdown Reader" (captured from a `fullname` field by the
-- archive detector's loose regex) and "markdownreader" (the real `name`) as the
-- same plugin, avoiding false-positive refusals during legitimate updates.
function AppStoreInstallHelpers.normalizePluginKey(name)
    if not name or name == "" then
        return ""
    end
    return (name:lower():gsub("[^%w]", ""))
end

-- Decide whether extracting a plugin named `plugin_name` into directory
-- `dirname` would clobber an already-installed, different plugin.
--
-- `existing_name` is the `name` read from the target directory's _meta.lua
-- (nil/"" if there is no _meta.lua, or if it exists but could not be read).
--
-- Returns nil when the extraction is safe, or one of:
--   "occupied_by_other"  - target holds a DIFFERENT, identifiable plugin
--   "unreadable_meta"    - a _meta.lua exists but its name could not be read
--   "unknown_name_clash" - target holds a different plugin and the incoming
--                           archive did not identify its own plugin name
function AppStoreInstallHelpers.decideCollision(existing_name, dirname, plugin_name)
    if not existing_name or existing_name == "" then
        return "unreadable_meta"
    end
    local incoming = plugin_name
    if not incoming or incoming == "" then
        -- Detection could not identify the incoming plugin's name. Only allow
        -- the overwrite when the existing plugin's name matches the directory
        -- basename (a well-formed, same-named plugin); otherwise refuse.
        incoming = (dirname or ""):gsub("%.koplugin$", "")
        if AppStoreInstallHelpers.normalizePluginKey(incoming) ~= AppStoreInstallHelpers.normalizePluginKey(existing_name) then
            return "unknown_name_clash"
        end
        return nil
    end
    if AppStoreInstallHelpers.normalizePluginKey(incoming) ~= AppStoreInstallHelpers.normalizePluginKey(existing_name) then
        return "occupied_by_other"
    end
    return nil
end

return AppStoreInstallHelpers
