local AppStoreSettings = require("appstore_settings")
local _ = require("appstore_gettext")
local socket_url = require("socket.url")

local ok_cfg, AppStoreConfig = pcall(require, "appstore_configuration")
if not ok_cfg or type(AppStoreConfig) ~= "table" then
    AppStoreConfig = {}
end

local SETTING_PRESET_KEY = "download_mirror_preset"
local SETTING_CUSTOM_URL_KEY = "download_mirror_custom_url"

-- Only these hosts get the mirror prefix. Every URL the plugin downloads today
-- is one of them, so the guard changes nothing now; it is here so that a URL
-- arriving from somewhere else later (a field in API data, a user-supplied
-- address) is not silently handed to a third-party proxy.
local MIRRORED_HOSTS = {
    ["github.com"] = true,
    ["www.github.com"] = true,
    ["api.github.com"] = true,
    ["codeload.github.com"] = true,
    ["raw.githubusercontent.com"] = true,
    ["objects.githubusercontent.com"] = true,
    ["gist.githubusercontent.com"] = true,
}

local PRESET_DEFS = {
    { id = "direct", name = _("Direct (GitHub)"), prefix = "" },
    { id = "gh_proxy_com", name = "gh-proxy.com", prefix = "https://gh-proxy.com/" },
    { id = "gh_ddlc_top", name = "gh.ddlc.top", prefix = "https://gh.ddlc.top/" },
    { id = "ghproxy_net", name = "ghproxy.net", prefix = "https://ghproxy.net/" },
    { id = "custom", name = _("Custom"), prefix = nil },
}

local Mirror = {}

-- The loop variable is deliberately not named `_`: that is the gettext
-- function this file uses for the preset names just above.
local function findPreset(preset_id)
    for idx = 1, #PRESET_DEFS do
        local preset = PRESET_DEFS[idx]
        if preset.id == preset_id then
            return preset
        end
    end
end

function Mirror.normalizeCustomUrl(value)
    if type(value) ~= "string" then
        return nil
    end
    value = value:match("^%s*(.-)%s*$")
    if value == "" or value:find("%s") then
        return nil
    end
    local parsed = socket_url.parse(value)
    local scheme = parsed and parsed.scheme and parsed.scheme:lower()
    if not parsed or (scheme ~= "http" and scheme ~= "https")
        or not parsed.host or parsed.host == ""
        or parsed.user or parsed.password or parsed.query or parsed.fragment or parsed.params then
        return nil
    end
    if parsed.port then
        local port = tonumber(parsed.port)
        if not port or port < 1 or port > 65535 then
            return nil
        end
    end
    if not value:match("/$") then
        value = value .. "/"
    end
    return value
end

function Mirror.getPresets()
    local list = {}
    for index = 1, #PRESET_DEFS do
        local item = PRESET_DEFS[index]
        table.insert(list, {
            id = item.id,
            name = item.name,
            prefix = item.prefix,
        })
    end
    return list
end

function Mirror.getCurrentPresetId()
    local preset_id = AppStoreSettings:readSetting(SETTING_PRESET_KEY)
    if not preset_id or preset_id == "" then
        if AppStoreConfig.download_mirror_preset then
            preset_id = AppStoreConfig.download_mirror_preset
        elseif AppStoreConfig.download_mirror_prefix then
            preset_id = "custom"
        else
            preset_id = "direct"
        end
    end
    if not findPreset(preset_id) then
        return "direct"
    end
    if preset_id == "custom" and Mirror.getCustomUrl() == "" then
        return "direct"
    end
    return preset_id
end

function Mirror.getCustomUrl()
    local custom = AppStoreSettings:readSetting(SETTING_CUSTOM_URL_KEY)
    if not custom or custom == "" then
        custom = AppStoreConfig.download_mirror_prefix or ""
    end
    return Mirror.normalizeCustomUrl(custom) or ""
end

function Mirror.getCurrentPrefix()
    local current_id = Mirror.getCurrentPresetId()
    if current_id == "custom" then
        return Mirror.getCustomUrl()
    end
    local preset = findPreset(current_id)
    return preset and preset.prefix or ""
end

function Mirror.getCurrentLabel()
    local current_id = Mirror.getCurrentPresetId()
    if current_id == "custom" then
        local custom_url = Mirror.getCustomUrl()
        return string.format(_("Custom (%s)"), custom_url)
    end
    local preset = findPreset(current_id) or PRESET_DEFS[1]
    return preset.name
end

function Mirror.setPreset(preset_id, custom_url)
    if not findPreset(preset_id) then
        return false, "unknown preset"
    end
    if preset_id == "custom" then
        custom_url = Mirror.normalizeCustomUrl(custom_url or Mirror.getCustomUrl())
        if not custom_url then
            return false, "invalid custom URL"
        end
        AppStoreSettings:saveSetting(SETTING_CUSTOM_URL_KEY, custom_url)
    end
    AppStoreSettings:saveSetting(SETTING_PRESET_KEY, preset_id)
    AppStoreSettings:flush()
    return true
end

--- True for a prefix that uses plain, unencrypted http.
-- These are accepted on purpose: a self-hosted mirror on a LAN has no
-- certificate to offer. Callers warn before storing one, because what comes
-- back through it is plugin code that gets extracted and run.
function Mirror.isInsecurePrefix(prefix)
    return type(prefix) == "string" and prefix:lower():find("^http://") ~= nil
end

-- Host of an http(s) URL, without any port or userinfo, lowercased.
local function urlHost(url)
    local authority = url:match("^https?://([^/?#]+)")
    if not authority then
        return nil
    end
    return authority:gsub("^[^@]*@", ""):gsub(":%d+$", ""):lower()
end

function Mirror.apply(url)
    if not url or url == "" then
        return url
    end
    local prefix = Mirror.getCurrentPrefix()
    if not prefix or prefix == "" then
        return url
    end
    -- Avoid duplicate prefixing
    if url:sub(1, #prefix) == prefix then
        return url
    end
    if not MIRRORED_HOSTS[urlHost(url) or ""] then
        return url
    end
    -- Convert GitHub's API zipball URL to a form supported by download mirrors.
    local owner, repo_name, ref = url:match("^https://api%.github%.com/repos/([^/]+)/([^/]+)/zipball/?([^?#]*)$")
    if owner and repo_name then
        if ref == "" then
            ref = "HEAD"
        end
        url = string.format("https://github.com/%s/%s/archive/%s.zip", owner, repo_name, ref)
    end
    return prefix .. url
end

return Mirror
