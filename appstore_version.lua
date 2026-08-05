-- appstore_version.lua
-- Version comparison, semver parsing, release tag evaluation, and ignored release management

local AppStoreVersion = {}

local PRERELEASE_KEYWORDS = {
    "alpha", "beta", "rc", "dev", "preview", "prerelease", "pre",
    "test", "nightly", "snapshot",
}

function AppStoreVersion.firstNonEmpty(...)
    for i = 1, select("#", ...) do
        local value = select(i, ...)
        if value ~= nil then
            if type(value) == "string" then
                if value ~= "" then
                    return value
                end
            else
                return value
            end
        end
    end
end

function AppStoreVersion.isPreReleaseTag(tag_name)
    if not tag_name or tag_name == "" then
        return false
    end
    local lower = tostring(tag_name):lower()
    for _, keyword in ipairs(PRERELEASE_KEYWORDS) do
        local init = 1
        while true do
            local s, e = lower:find(keyword, init, true)
            if not s then
                break
            end
            local before = (s == 1) and "" or lower:sub(s - 1, s - 1)
            local after = (e == #lower) and "" or lower:sub(e + 1, e + 1)
            local ok_before = (before == "") or before:match("[%-%.%_%+%d]") ~= nil
            local ok_after = (after == "") or after:match("[%-%.%_%+%d]") ~= nil
            if ok_before and ok_after then
                return true
            end
            init = s + 1
        end
    end
    return false
end

function AppStoreVersion.isDateBasedVersion(version_str)
    if not version_str then
        return false
    end

    local year, month, day = version_str:match("^(%d%d%d%d)%.(%d+)%.(%d+)$")
    if year then
        local y = tonumber(year)
        local m = tonumber(month)
        local d = tonumber(day)

        if y >= 2000 and y <= 2100 and m >= 1 and m <= 12 and d >= 1 and d <= 31 then
            return true
        end
    end

    return false
end

function AppStoreVersion.parseVersionFromTag(tag_name)
    if not tag_name or tag_name == "" then
        return nil
    end

    local cleaned = tostring(tag_name):gsub("^[vV]", "")
    cleaned = cleaned:gsub("^release%-?", "")
    cleaned = cleaned:gsub("^version%-?", "")
    cleaned = cleaned:gsub("^plugin%-?", "")

    -- Strip build metadata (e.g., +build.123)
    cleaned = cleaned:gsub("%+.*$", "")

    local patterns = {
        "^(%d+%.%d+%.%d+[%w%-%.]*)",
        "^(%d+%.%d+[%w%-%.]*)",
        "^(%d+)",
    }

    for _, pattern in ipairs(patterns) do
        local version = cleaned:match(pattern)
        if version then
            return version
        end
    end

    return nil
end

local function compareIdentifiers(a, b)
    local function split(x)
        local t = {}
        for part in tostring(x):gmatch("[^.]+") do
            t[#t + 1] = part
        end
        return t
    end
    local ta, tb = split(a), split(b)
    for i = 1, math.max(#ta, #tb) do
        local x, y = ta[i], tb[i]
        if x == nil then return -1 end
        if y == nil then return 1 end
        local nx, ny = tonumber(x), tonumber(y)
        if nx and ny then
            if nx ~= ny then return nx < ny and -1 or 1 end
        elseif nx then
            return -1
        elseif ny then
            return 1
        elseif x ~= y then
            return x < y and -1 or 1
        end
    end
    return 0
end

function AppStoreVersion.isVersionNewer(v1_str, v2_str)
    if not v1_str or not v2_str then
        return false
    end
    if tostring(v1_str) == tostring(v2_str) then
        return false
    end

    local function splitVersion(v_str)
        local str = (tostring(v_str):gsub("^[vV]", ""))
        str = (str:gsub("%+.*$", ""))
        local pre
        local dash = str:find("-", 1, true)
        if dash then
            pre = str:sub(dash + 1):lower()
            str = str:sub(1, dash - 1)
        end
        local core, post = {}, nil
        for part in str:gmatch("[^.]+") do
            local num, tail = part:match("^(%d*)(.*)$")
            core[#core + 1] = tonumber(num) or 0
            if tail ~= "" then
                post = tail:lower()
            end
        end
        return core, pre, post
    end

    local c1, pre1, post1 = splitVersion(v1_str)
    local c2, pre2, post2 = splitVersion(v2_str)

    for i = 1, math.max(#c1, #c2) do
        local a = c1[i] or 0
        local b = c2[i] or 0
        if a > b then return true end
        if a < b then return false end
    end

    if pre1 ~= pre2 then
        if not pre1 then return true end
        if not pre2 then return false end
        return compareIdentifiers(pre1, pre2) > 0
    end

    if post1 ~= post2 then
        if not post1 then return false end
        if not post2 then return true end
        return compareIdentifiers(post1, post2) > 0
    end

    return false
end

local IGNORED_RELEASES_KEY = "ignored_releases"

function AppStoreVersion.getIgnoredReleases(settings)
    if not settings then return {} end
    return settings:readSetting(IGNORED_RELEASES_KEY) or {}
end

function AppStoreVersion.saveIgnoredReleases(settings, ignored_releases)
    if not settings then return end
    settings:saveSetting(IGNORED_RELEASES_KEY, ignored_releases)
    settings:flush()
end

function AppStoreVersion.ignoreRelease(settings, owner, repo_name, version)
    if not owner or not repo_name or not version then
        return
    end
    local key = string.format("%s/%s", owner, repo_name)
    local ignored = AppStoreVersion.getIgnoredReleases(settings)
    ignored[key] = version
    AppStoreVersion.saveIgnoredReleases(settings, ignored)
end

function AppStoreVersion.clearIgnoredRelease(settings, owner, repo_name)
    if not owner or not repo_name then
        return
    end
    local key = string.format("%s/%s", owner, repo_name)
    local ignored = AppStoreVersion.getIgnoredReleases(settings)
    if ignored[key] then
        ignored[key] = nil
        AppStoreVersion.saveIgnoredReleases(settings, ignored)
    end
end

function AppStoreVersion.getIgnoredVersion(settings, owner, repo_name)
    if not owner or not repo_name then
        return nil
    end
    local key = string.format("%s/%s", owner, repo_name)
    local ignored = AppStoreVersion.getIgnoredReleases(settings)
    return ignored[key]
end

function AppStoreVersion.isReleaseIgnored(settings, owner, repo_name, version)
    local ignored_version = AppStoreVersion.getIgnoredVersion(settings, owner, repo_name)
    return ignored_version == version
end

return AppStoreVersion
