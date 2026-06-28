local DataStorage = require("datastorage")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local FileManager = require("apps/filemanager/filemanager")
local _ = require("gettext")
local http = require("socket.http")
local ltn12 = require("ltn12")
local util = require("util")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")

local RepoContent = {}

local function buildRawUrl(owner, repo)
    return string.format("https://raw.githubusercontent.com/%s/%s/HEAD/README.md", owner, repo)
end

local function download(url)
    local response = {}
    local _, code = http.request{
        url = url,
        sink = ltn12.sink.table(response),
        headers = {
            ["Accept"] = "text/plain",
            ["User-Agent"] = "KOReader-AppStore",
        },
    }
    return tonumber(code), table.concat(response)
end

function RepoContent.fetchReadme(owner, repo)
    if not owner or not repo then
        return nil, "missing owner/repo"
    end
    local url = buildRawUrl(owner, repo)
    local code, body = download(url)
    if code ~= 200 then
        return nil, string.format("HTTP %s", tostring(code))
    end
    if not body or body == "" then
        return nil, "empty body"
    end
    -- Strip inline HTML <img> tags to avoid rendering issues in the text viewer.
    -- This keeps the textual README content while dropping embedded images.
    body = body:gsub("<img[^>]->", "")
    return body, nil
end

return RepoContent

