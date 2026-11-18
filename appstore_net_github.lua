local json = require("json")
local Net = require("appstore_net")
local url = require("socket.url")
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

-- Seconds to wait before each retry of a 5xx. GitHub's server errors are nearly always
-- passing -- a search that ran out of time on their side, a deploy -- and gone on the next
-- try. Timeouts and refused connections are not retried: on a network that is down, each
-- retry would only hold the interface up for another full timeout.
GitHubClient.SERVER_ERROR_RETRY_DELAYS = { 1, 3 }

-- How a retry waits. A field so the refresh can swap in a wait that keeps reading input
-- (Back still stops it), and the tests one that does not wait at all.
function GitHubClient.wait(seconds)
    require("ffi/util").sleep(seconds)
end

local function requestOnce(target, headers)
    local response_body = {}
    -- Without a deadline a single stalled connection hangs the interface for good: every
    -- one of these runs on the UI thread. The API answers in well under a second when it
    -- answers at all, so the large-content values are already generous.
    local code, response_headers, status = Net.requestToTable({
        url = target,
        headers = headers,
    }, response_body)
    if not code then
        return status, "", {}
    end
    -- A timeout reports itself as a string where a status would be. Callers only ever
    -- compare against 200, so passing it through keeps them working and names the reason
    -- in their logs instead of turning it into a bare nil.
    return tonumber(code) or code, table.concat(response_body), response_headers or {}
end

-- Returns `code, body, headers`; header names are lower-case, as luasocket gives them.
local function request(path, query)
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
    local code, body, response_headers = requestOnce(target, headers)
    for _, delay in ipairs(GitHubClient.SERVER_ERROR_RETRY_DELAYS) do
        if type(code) ~= "number" or code < 500 or code > 599 then
            break
        end
        logger.warn("AppStore: GitHub server error, retrying in", delay, "s:", code, target)
        GitHubClient.wait(delay)
        code, body, response_headers = requestOnce(target, headers)
    end
    return code, body, response_headers
end

-- How long to wait out the rate limit behind `err_info` (from searchRepositories), in
-- seconds from `now`, or nil when GitHub did not say. Retry-After comes with the secondary
-- limits; X-RateLimit-Reset with the primary one, as the epoch second the window reopens.
function GitHubClient.rateLimitDelay(err_info, now)
    if type(err_info) ~= "table" or not err_info.is_rate_limit then
        return nil
    end
    local retry_after = tonumber(err_info.retry_after)
    if retry_after then
        return math.max(1, math.ceil(retry_after))
    end
    local reset_at = tonumber(err_info.reset_at)
    if reset_at then
        -- One second past the reset: GitHub's clock and ours are not the same clock.
        return math.max(1, reset_at - (now or os.time()) + 1)
    end
    return nil
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
    -- GitHub search only returns the first 1000 results; requesting past
    -- that returns 422, so return an empty page and let callers stop.
    if ((opts.page or 1) - 1) * (opts.per_page or 30) >= 1000 then
        return { items = {}, total_count = 0 }, nil
    end
    local query = buildQuery(opts)
    local code, body, response_headers = request("/search/repositories", query)
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
            -- For rateLimitDelay, so a caller can wait the limit out instead of failing.
            retry_after = response_headers["retry-after"],
            reset_at = response_headers["x-ratelimit-reset"],
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

return GitHubClient

