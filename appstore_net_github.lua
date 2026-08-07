local http = require("socket.http")
local json = require("json")
local url = require("socket.url")
local socketutil = require("socketutil")
local logger = require("logger")

local ok_cfg, AppStoreConfig = pcall(require, "appstore_configuration")
if not ok_cfg then
    AppStoreConfig = {}
end

local GitHubClient = {}

local BASE_URL = "https://api.github.com"
local USER_AGENT = "KOReader-AppStore"

local function joinQueryParts(parts)
    if not parts or #parts == 0 then
        return ""
    end
    return table.concat(parts, " ")
end

-- socketutil.table_sink, not a hand-rolled sink: luasocket's total timeout is
-- reset between polls, so it is only actually enforced by socketutil's sinks.
-- Without this the LARGE_TOTAL_TIMEOUT set below would not bound anything and
-- a trickling response could still hang the UI thread indefinitely.
-- It reads socketutil.total_timeout when constructed, so set_timeout must run
-- before the request table is built -- it does.
local function newTableSink(target)
    return socketutil.table_sink(target)
end

local function getAuthHeaders()
    local auth = AppStoreConfig.auth and AppStoreConfig.auth.github
    if not auth then
        return nil
    end
    local token = auth.token
    if not token or token == "" or token == "your_github_token" then
        return nil
    end
    local scheme = auth.scheme or "token"
    return {
        ["Authorization"] = string.format("%s %s", scheme, token),
    }
end

-- Hosts this client is willing to talk to. A redirect leaving this set is
-- refused rather than followed.
local ALLOWED_HOSTS = {
    ["api.github.com"] = true,
    ["github.com"] = true,
    ["codeload.github.com"] = true,
    ["objects.githubusercontent.com"] = true,
    ["raw.githubusercontent.com"] = true,
    ["release-assets.githubusercontent.com"] = true,
}

local MAX_REDIRECTS = 5

-- Follow redirects manually instead of letting luasocket do it.
--
-- luasocket's default is redirect = true, and its tredirect() copies reqt.headers
-- verbatim into the follow-up request -- to any host, over any scheme. Since
-- these requests carry the user's GitHub PAT in an Authorization header, a 30x
-- pointing elsewhere would hand the token to that host, in cleartext if the
-- Location is http://. Driving redirects here lets us (a) refuse non-https,
-- (b) refuse unexpected hosts, and (c) re-attach Authorization only while the
-- target is still api.github.com.
--
-- Timeouts are set per attempt: without them a stalled socket hangs the UI
-- thread with no way out, which is exactly what happens on flaky device wifi.
local function requestWithGuardedRedirects(target, headers)
    local current = target
    for _ = 0, MAX_REDIRECTS do
        local parsed = url.parse(current)
        if not parsed then
            return 0, "unparseable URL"
        end
        local host = (parsed.host or ""):lower()
        -- url.parse does not normalise the scheme; "HTTPS://" is legal.
        if (parsed.scheme or ""):lower() ~= "https" then
            logger.warn("AppStore: refusing non-https URL", current)
            return 0, "refusing non-https URL"
        end
        if not ALLOWED_HOSTS[host] then
            logger.warn("AppStore: refusing unexpected host", host)
            return 0, "refusing unexpected host: " .. host
        end

        local send_headers = {}
        for k, v in pairs(headers) do
            send_headers[k] = v
        end
        if host ~= "api.github.com" then
            send_headers["Authorization"] = nil
        end

        local response_body = {}
        -- LARGE_*, not DEFAULT_*: socketutil.DEFAULT_TOTAL_TIMEOUT is -1, i.e.
        -- "no total timeout" (it is the value reset_timeout restores), so using
        -- it here would leave the hang this is meant to prevent.
        socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
        local _, code, resp_headers = http.request{
            url = current,
            headers = send_headers,
            sink = newTableSink(response_body),
            redirect = false,
        }
        socketutil:reset_timeout()

        code = tonumber(code)
        if code == 301 or code == 302 or code == 303 or code == 307 or code == 308 then
            local location = resp_headers and (resp_headers.location or resp_headers.Location)
            if not location or location == "" then
                return code, table.concat(response_body)
            end
            current = url.absolute(current, location)
        else
            return code or 0, table.concat(response_body)
        end
    end
    logger.warn("AppStore: too many redirects for", target)
    return 0, "too many redirects"
end

local NetworkMgr = require("ui/network/manager")

local function request(path, query)
    if NetworkMgr and NetworkMgr.isOnline and not NetworkMgr:isOnline() then
        logger.dbg("AppStore HTTP offline check failed", path)
        return 0, "offline"
    end
    local target = BASE_URL .. path
    if query and query ~= "" then
        target = target .. "?" .. query
    end
    logger.dbg("AppStore HTTP", target)
    local headers = {
        ["Accept"] = "application/vnd.github+json",
        ["User-Agent"] = USER_AGENT,
    }
    local auth_headers = getAuthHeaders()
    if auth_headers then
        for key, value in pairs(auth_headers) do
            headers[key] = value
        end
    end
    return requestWithGuardedRedirects(target, headers)
end

local function buildQuery(opts)
    local query_parts = {}
    if opts.q and opts.q ~= "" then
        table.insert(query_parts, "q=" .. url.escape(opts.q))
    end
    if opts.sort and opts.sort ~= "" then
        table.insert(query_parts, "sort=" .. opts.sort)
    end
    if opts.order and opts.order ~= "" then
        table.insert(query_parts, "order=" .. opts.order)
    end
    table.insert(query_parts, "page=" .. tostring(opts.page or 1))
    table.insert(query_parts, "per_page=" .. tostring(opts.per_page or 30))
    return table.concat(query_parts, "&")
end

local function buildTopicQuery(topics, extra_terms)
    local parts = {}
    if topics then
        for _, topic in ipairs(topics) do
            if topic and topic ~= "" then
                table.insert(parts, string.format("topic:%s", topic))
            end
        end
    end
    if extra_terms and extra_terms ~= "" then
        table.insert(parts, extra_terms)
    end
    return joinQueryParts(parts)
end

function GitHubClient.searchRepositories(opts)
    opts = opts or {}
    local query = buildQuery(opts)
    local code, body = request("/search/repositories", query)
    if code ~= 200 then
        logger.warn("GitHub search error", code, body)
        -- GitHub's search endpoint rejects fine-grained PATs outright (they're
        -- not in its list of supported token types), returning a 403 with this
        -- wording rather than an actual rate-limit response. Classic tokens work.
        local is_fine_grained_unsupported = code == 403
            and body
            and body:lower():find("fine%-grained", 1, true) ~= nil
        local err_info = {
            code = code,
            body = body,
            is_rate_limit = (code == 403 or code == 429) and not is_fine_grained_unsupported,
            is_fine_grained_unsupported = is_fine_grained_unsupported,
        }
        return nil, err_info
    end
    local ok, parsed = pcall(json.decode, body)
    if not ok then
        logger.warn("GitHub search decode error", parsed)
        return nil, { code = 0, body = "decode", is_rate_limit = false }
    end
    return parsed, nil
end

function GitHubClient.hasAuthToken()
    local auth = AppStoreConfig.auth and AppStoreConfig.auth.github
    if not auth then
        return false
    end
    local token = auth.token
    if not token or token == "" or token =="your_github_token" then
        return false
    end
    return true
end

function GitHubClient.searchByTopics(topics, opts)
    opts = opts or {}
    local q = buildTopicQuery(topics, opts.extra)
    opts.q = q
    opts.sort = opts.sort or "stars"
    opts.order = opts.order or "desc"
    opts.per_page = opts.per_page or 100
    return GitHubClient.searchRepositories(opts)
end

function GitHubClient.fetchRepoTree(owner, repo, ref)
    if not owner or not repo then
        return nil, "missing owner/repo"
    end
    ref = ref or "HEAD"
    local path = string.format("/repos/%s/%s/git/trees/%s", owner, repo, ref)
    local code, body = request(path, "recursive=1")
    if code ~= 200 then
        logger.warn("GitHub fetch tree error", owner .. "/" .. repo, ref, code, body)
        return nil, { code = code, body = body }
    end
    local ok, parsed = pcall(json.decode, body)
    if not ok then
        logger.warn("GitHub fetch tree decode error", parsed)
        return nil, "decode"
    end
    return parsed, nil
end

function GitHubClient.fetchRepoMetadata(owner, repo)
    if not owner or not repo then
        return nil, "missing owner/repo"
    end
    local path = string.format("/repos/%s/%s", owner, repo)
    local code, body = request(path)
    if code ~= 200 then
        logger.warn("GitHub fetch repo metadata error", owner .. "/" .. repo, code, body)
        return nil, { code = code, body = body }
    end
    local ok, parsed = pcall(json.decode, body)
    if not ok then
        logger.warn("GitHub fetch repo metadata decode error", parsed)
        return nil, "decode"
    end
    return parsed, nil
end

function GitHubClient.fetchLatestRelease(owner, repo)
    if not owner or not repo then
        return nil, "missing owner/repo"
    end
    local path = string.format("/repos/%s/%s/releases/latest", owner, repo)
    local code, body = request(path)
    if code ~= 200 then
        logger.warn("GitHub fetch latest release error", owner .. "/" .. repo, code, body)
        return nil, { code = code, body = body }
    end
    local ok, parsed = pcall(json.decode, body)
    if not ok then
        logger.warn("GitHub fetch latest release decode error", parsed)
        return nil, "decode"
    end
    return parsed, nil
end

-- Fetch all releases of a repository (sorted from newest to oldest by GitHub).
-- Pagination is performed transparently up to `max_pages` to avoid hammering
-- the API for repositories with hundreds of releases.
function GitHubClient.fetchReleases(owner, repo, opts)
    if not owner or not repo then
        return nil, "missing owner/repo"
    end
    opts = opts or {}
    local per_page = tonumber(opts.per_page) or 100
    local max_pages = tonumber(opts.max_pages) or 5
    local results = {}
    for page = 1, max_pages do
        local path = string.format("/repos/%s/%s/releases", owner, repo)
        local query = string.format("per_page=%d&page=%d", per_page, page)
        local code, body = request(path, query)
        if code ~= 200 then
            logger.warn("GitHub fetch releases error", owner .. "/" .. repo, code, body)
            if #results > 0 then
                return results, nil
            end
            return nil, { code = code, body = body }
        end
        local ok, parsed = pcall(json.decode, body)
        if not ok or type(parsed) ~= "table" then
            logger.warn("GitHub fetch releases decode error", parsed)
            if #results > 0 then
                return results, nil
            end
            return nil, "decode"
        end
        if #parsed == 0 then
            break
        end
        for _, rel in ipairs(parsed) do
            table.insert(results, rel)
        end
        if #parsed < per_page then
            break
        end
    end
    return results, nil
end

-- Fetch the list of commits between two refs (tags, branches, SHAs).
-- Uses the GitHub compare endpoint: /repos/{owner}/{repo}/compare/{base}...{head}
-- Returns the parsed JSON table (contains `commits`, `total_commits`, etc.) or nil + err.
function GitHubClient.fetchCompareCommits(owner, repo, base, head)
    if not owner or not repo or not base or not head then
        return nil, "missing parameters"
    end
    local path = string.format("/repos/%s/%s/compare/%s...%s", owner, repo, base, head)
    local code, body = request(path)
    if code ~= 200 then
        logger.warn("GitHub compare error", owner .. "/" .. repo, base .. "..." .. head, code, body)
        return nil, { code = code, body = body }
    end
    local ok, parsed = pcall(json.decode, body)
    if not ok then
        logger.warn("GitHub compare decode error", parsed)
        return nil, "decode"
    end
    return parsed, nil
end

function GitHubClient.runWhenOnline(callback)
    if NetworkMgr and NetworkMgr.runWhenOnline then
        NetworkMgr:runWhenOnline(callback)
    else
        callback()
    end
end

return GitHubClient

