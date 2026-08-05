-- appstore_installer.lua
-- Package download, zip extraction, Zip Slip validation, patch/plugin installation & uninstallation routines

local http = require("socket.http")
local socket = require("socket")
local socketutil = require("socketutil")
local socket_url = require("socket.url")
local lfs = require("libs/libkoreader-lfs")
local sha2 = require("ffi/sha2")
local util = require("util")
local ffiUtil = require("ffi/util")
local logger = require("logger")
local _ = require("appstore_gettext")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Spinner = require("ui/widget/spinner")
local PluginPaths = require("appstore_plugin_paths")

local AppStoreInstaller = {}

local DOWNLOAD_ALLOWED_HOSTS = {
    ["api.github.com"] = true,
    ["github.com"] = true,
    ["codeload.github.com"] = true,
    ["objects.githubusercontent.com"] = true,
    ["raw.githubusercontent.com"] = true,
    ["release-assets.githubusercontent.com"] = true,
}

function AppStoreInstaller.computeFileSha1(path)
    if not path or path == "" then
        return nil
    end
    local file = io.open(path, "rb")
    if not file then
        return nil
    end
    local content = file:read("*a")
    file:close()
    if not content then
        return nil
    end
    local header = string.format("blob %d", #content)
    return sha2.sha1(header .. "\0" .. content)
end

function AppStoreInstaller.downloadToFile(url, local_path)
    local dir = local_path:match("^(.*)/")
    if dir and dir ~= "" then
        util.makePath(dir)
    end

    local current = url
    for _ = 0, 5 do
        local parsed = socket_url.parse(current)
        if not parsed then
            util.removeFile(local_path)
            return false, "unparseable download URL"
        end
        local host = (parsed.host or ""):lower()
        if (parsed.scheme or ""):lower() ~= "https" then
            util.removeFile(local_path)
            return false, "refusing non-https download URL"
        end
        if not DOWNLOAD_ALLOWED_HOSTS[host] then
            util.removeFile(local_path)
            return false, "refusing download from unexpected host: " .. host
        end

        local file, err = io.open(local_path, "wb")
        if not file then
            return false, err or "failed to open file for writing"
        end

        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
        local code, headers, status = socket.skip(1, http.request{
            url = current,
            method = "GET",
            sink = socketutil.file_sink(file),
            redirect = false,
            headers = {
                ["User-Agent"] = socketutil.USER_AGENT,
                ["Accept"] = "application/zip, application/octet-stream, text/plain",
            },
        })
        socketutil:reset_timeout()

        if code == socketutil.TIMEOUT_CODE
            or code == socketutil.SSL_HANDSHAKE_CODE
            or code == socketutil.SINK_TIMEOUT_CODE then
            util.removeFile(local_path)
            return false, status or code or "timeout"
        end

        if not headers then
            util.removeFile(local_path)
            return false, status or code or "network error"
        end

        local numeric = tonumber(code)
        if numeric == 301 or numeric == 302 or numeric == 303
            or numeric == 307 or numeric == 308 then
            local location = headers.location or headers.Location
            if not location or location == "" then
                util.removeFile(local_path)
                return false, "redirect without a location"
            end
            current = socket_url.absolute(current, location)
        elseif numeric == 200 then
            return true
        else
            util.removeFile(local_path)
            return false, status or tostring(code)
        end
    end

    util.removeFile(local_path)
    return false, "too many redirects"
end

function AppStoreInstaller.buildPatchDownloadUrl(owner, repo, branch, path)
    if not owner or not repo or not path then
        return nil
    end
    branch = branch or "HEAD"
    local clean_path = path:gsub("^/+", "")
    return string.format("https://raw.githubusercontent.com/%s/%s/%s/%s", owner, repo, branch, clean_path)
end

function AppStoreInstaller.fetchGitHubRaw(owner, repo, path, branch)
    if not owner or not repo or not path then
        return nil, "missing parameters"
    end
    branch = branch or "HEAD"
    local download_url = AppStoreInstaller.buildPatchDownloadUrl(owner, repo, branch, path)
    local response_body = {}
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local request = {
        url = download_url,
        method = "GET",
        sink = function(chunk, err)
            if chunk then table.insert(response_body, chunk) end
            return 1, err
        end,
        redirect = true,
        headers = {
            ["User-Agent"] = socketutil.USER_AGENT,
        },
    }
    local code, headers, status = socket.skip(1, http.request(request))
    socketutil:reset_timeout()
    if code ~= 200 then
        return nil, status or tostring(code)
    end
    return table.concat(response_body), nil
end

function AppStoreInstaller.canonicalizePath(path)
    if not path then return "" end
    path = path:gsub("\\", "/")
    local parts = {}
    for part in path:gmatch("[^/]+") do
        if part == ".." then
            if #parts > 0 and parts[#parts] ~= ".." then
                table.remove(parts)
            end
        elseif part ~= "." and part ~= "" then
            table.insert(parts, part)
        end
    end
    local prefix = path:sub(1, 1) == "/" and "/" or ""
    return prefix .. table.concat(parts, "/")
end

function AppStoreInstaller.isSubPath(parent, child)
    local norm_parent = AppStoreInstaller.canonicalizePath(parent)
    local norm_child = AppStoreInstaller.canonicalizePath(child)
    if norm_parent == norm_child then
        return true
    end
    if not norm_parent:find("/$") then
        norm_parent = norm_parent .. "/"
    end
    return norm_child:sub(1, #norm_parent) == norm_parent
end

function AppStoreInstaller.extractPluginToUserDir(reader, info, dest_root)
    dest_root = dest_root or PluginPaths.getDefaultPluginsRoot()
    util.makePath(dest_root)
    local target_dir = dest_root .. "/" .. info.plugin_dirname
    local canonical_target = AppStoreInstaller.canonicalizePath(target_dir)

    local planned = {}
    local archive_relatives = {}
    for entry in reader:iterate() do
        if entry.mode == "file" then
            local relative
            if info.plugin_root == "" then
                relative = entry.path
            elseif entry.path:sub(1, #info.plugin_root + 1) == info.plugin_root .. "/" then
                relative = entry.path:sub(#info.plugin_root + 2)
            end
            if relative then
                if not AppStoreInstaller.isSubPath(canonical_target, target_dir .. "/" .. relative) then
                    return false, _("Security error: Archive entry escapes target directory: ") .. entry.path
                end
                planned[#planned + 1] = { path = entry.path, relative = relative }
                archive_relatives[relative] = true
            end
        end
    end

    if #planned == 0 then
        return false, _("Archive contains no installable files.")
    end

    local staging_dir = target_dir .. ".new"
    local backup_dir = target_dir .. ".bak"

    local function purge(path)
        if lfs.attributes(path, "mode") == "directory" then
            pcall(ffiUtil.purgeDir, path)
        end
    end

    purge(staging_dir)
    util.makePath(staging_dir)

    for _, item in ipairs(planned) do
        local dest_path = staging_dir .. "/" .. item.relative
        local parent = dest_path:match("^(.*)/")
        if parent and parent ~= "" then
            util.makePath(parent)
        end
        if not reader:extractToPath(item.path, dest_path) then
            purge(staging_dir)
            return false, _("Failed to extract file: ") .. item.path
        end
    end

    if lfs.attributes(target_dir, "mode") == "directory" then
        local carry_err
        local function carryOver(dir, prefix)
            for f in lfs.dir(dir) do
                if carry_err then
                    return
                end
                if f ~= "." and f ~= ".." then
                    local rel = (prefix == "") and f or (prefix .. "/" .. f)
                    local full = dir .. "/" .. f
                    local mode = lfs.attributes(full, "mode")
                    if mode == "directory" then
                        carryOver(full, rel)
                    elseif mode == "file" and not archive_relatives[rel] then
                        local dest = staging_dir .. "/" .. rel
                        local parent = dest:match("^(.*)/")
                        if parent and parent ~= "" then
                            util.makePath(parent)
                        end
                        local copy_err = ffiUtil.copyFile(full, dest)
                        if copy_err then
                            carry_err = tostring(copy_err) .. " (" .. rel .. ")"
                        end
                    end
                end
            end
        end
        carryOver(target_dir, "")
        if carry_err then
            purge(staging_dir)
            return false, _("Failed to preserve existing plugin files: ") .. carry_err
        end
    end

    local had_existing = lfs.attributes(target_dir, "mode") == "directory"
    if had_existing then
        purge(backup_dir)
        local ok_bak, bak_err = os.rename(target_dir, backup_dir)
        if not ok_bak then
            purge(staging_dir)
            return false, _("Failed to install: ") .. tostring(bak_err)
        end
    end

    local ok_swap, swap_err = os.rename(staging_dir, target_dir)
    if not ok_swap then
        if had_existing then
            local restored = os.rename(backup_dir, target_dir)
            if not restored then
                logger.err("AppStore: could not restore", target_dir, "-- the previous version is left at", backup_dir)
            end
        end
        purge(staging_dir)
        return false, _("Failed to install: ") .. tostring(swap_err)
    end

    purge(backup_dir)
    return true, target_dir
end

function AppStoreInstaller.showSpinner(title)
    local spinner = Spinner:new{ text = title or _("Working…") }
    UIManager:show(spinner)
    return spinner
end

function AppStoreInstaller.closeSpinner(spinner)
    if spinner then
        UIManager:close(spinner)
    end
end

return AppStoreInstaller
