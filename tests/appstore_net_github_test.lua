-- appstore_net_github_test.lua
-- Run with a plain LuaJIT, from the plugin folder or from a KOReader tree:
--   luajit tests/appstore_net_github_test.lua
--   ./luajit plugins/appstore.koplugin/tests/appstore_net_github_test.lua
--
-- The HTTP layer (appstore_net) is replaced by a script of canned responses, so
-- this checks what the client does with them: retrying GitHub's passing server
-- errors, and reporting rate limits with enough to wait them out.
package.path = "plugins/appstore.koplugin/?.lua;./?.lua;" .. package.path

-- Canned responses, consumed one per request.
local script, requests = {}, {}
package.preload["appstore_net"] = function()
    return {
        requestToTable = function(request, parts)
            requests[#requests + 1] = request.url
            local r = table.remove(script, 1)
            assert(r, "no canned response left for " .. request.url)
            parts[#parts + 1] = r.body or ""
            return r.code, r.headers or {}, r.status
        end,
    }
end
-- Bodies are names of tables below rather than JSON: the client only hands
-- them to json.decode.
local bodies = {
    search = { total_count = 1, items = { { full_name = "a/b.koplugin" } } },
    releases = { { tag_name = "v1" } },
}
package.preload["json"] = function()
    return {
        decode = function(s)
            local v = bodies[s]
            if v == nil then error("undecodable: " .. tostring(s)) end
            return v
        end,
    }
end
package.preload["socket.url"] = function() return { escape = function(s) return s end } end
package.preload["logger"] = function()
    local nop = function() end
    return { dbg = nop, info = nop, warn = nop, err = nop }
end
package.preload["appstore_configuration"] = function() return {} end

local GitHub = require("appstore_net_github")
local waits = {}
GitHub.wait = function(seconds) waits[#waits + 1] = seconds end

local failures = 0
local function check(label, got, expected)
    if got == expected then
        print("PASS", label)
    else
        failures = failures + 1
        print("FAIL", label, "expected=", tostring(expected), "got=", tostring(got))
    end
end

local function reset(responses)
    script, requests, waits = responses, {}, {}
    GitHub.wait = function(seconds) waits[#waits + 1] = seconds end
end

-- ── Server errors are retried ───────────────────────────────────────────────
do
    reset({ { code = 502, body = "{}" }, { code = 503, body = "{}" }, { code = 200, body = "search" } })
    local parsed, err = GitHub.searchRepositories({ q = "x" })
    check("5xx twice then 200: result returned", parsed and parsed.total_count, 1)
    check("5xx twice then 200: no error", err, nil)
    check("5xx twice then 200: three requests", #requests, 3)
    check("5xx twice then 200: waited twice", #waits, 2)
    check("5xx twice then 200: waits grow", (waits[1] or 0) < (waits[2] or 0), true)
end

do
    reset({ { code = 502, body = "{}" }, { code = 502, body = "{}" }, { code = 502, body = "{}" } })
    local parsed, err = GitHub.searchRepositories({ q = "x" })
    check("5xx three times: gives up", parsed, nil)
    check("5xx three times: reports the status", err and err.code, 502)
    check("5xx three times: three requests, no more", #requests, 3)
    check("5xx three times: not a rate limit", err and err.is_rate_limit, false)
end

do
    reset({ { code = 500, body = "{}" }, { code = 200, body = "releases" } })
    local releases = GitHub.fetchReleases("o", "r", { max_pages = 1 })
    check("other endpoints retried too", releases and #releases, 1)
end

-- ── Everything else is not ──────────────────────────────────────────────────
do
    reset({ { code = 404, body = "{}" } })
    local parsed, err = GitHub.searchRepositories({ q = "x" })
    check("404: no retry", #requests, 1)
    check("404: reported", parsed == nil and err and err.code, 404)
end

do
    reset({ { code = "timeout", body = "" } })
    local _, err = GitHub.searchRepositories({ q = "x" })
    check("timeout: no retry (a stalled network would only stall longer)", #requests, 1)
    check("timeout: reported", err and err.code, "timeout")
end

-- ── Rate limits carry what it takes to wait them out ────────────────────────
do
    reset({ {
        code = 403, body = "{}",
        headers = { ["x-ratelimit-remaining"] = "0", ["x-ratelimit-reset"] = "1700000030" },
    } })
    local _, err = GitHub.searchRepositories({ q = "x" })
    check("403 rate limit: not retried here", #requests, 1)
    check("403 rate limit: flagged", err and err.is_rate_limit, true)
    check("403 rate limit: wait until reset", GitHub.rateLimitDelay(err, 1700000000), 31)
end

do
    reset({ { code = 429, body = "{}", headers = { ["retry-after"] = "20" } } })
    local _, err = GitHub.searchRepositories({ q = "x" })
    check("429 Retry-After: honoured", GitHub.rateLimitDelay(err, 1700000000), 20)
end

do
    -- A 429 is a rate limit whatever its headers; without them, GitHub asks for a minute.
    reset({ { code = 429, body = "{}" } })
    local _, err = GitHub.searchRepositories({ q = "x" })
    check("429 without headers: a rate limit", err and err.is_rate_limit, true)
    check("429 without headers: a minute's wait", GitHub.rateLimitDelay(err, 1700000000), 60)
end

do
    -- Out of requests with no reset given: a minute, as the site does.
    reset({ { code = 403, body = "{}", headers = { ["x-ratelimit-remaining"] = "0" } } })
    local _, err = GitHub.searchRepositories({ q = "x" })
    check("403 out of requests, no reset: a minute's wait", GitHub.rateLimitDelay(err, 1700000000), 60)
end

-- ── Fine-grained tokens, which search refuses ───────────────────────────────
do
    reset({ {
        code = 403,
        body = '{"message":"Fine-grained personal access tokens are not supported for this endpoint."}',
        headers = { ["x-ratelimit-remaining"] = "29" },
    } })
    local _, err = GitHub.searchRepositories({ q = "x" })
    check("fine-grained token: recognised", err and err.is_fine_grained_unsupported, true)
    check("fine-grained token: not a rate limit", err and err.is_rate_limit, false)
end

do
    -- Out of requests, yet the reset is already behind us: our clock is ahead of
    -- GitHub's, and how far is unknown. A whole search window is the safe wait.
    reset({ {
        code = 403, body = "{}",
        headers = { ["x-ratelimit-remaining"] = "0", ["x-ratelimit-reset"] = "1699999990" },
    } })
    local _, err = GitHub.searchRepositories({ q = "x" })
    check("reset already past: a full window, not a second", GitHub.rateLimitDelay(err, 1700000000), 61)
end

-- ── GitHub's clock, not the device's ────────────────────────────────────────
-- 1700000000 is Tue, 14 Nov 2023 22:13:20 GMT.
do
    reset({ {
        code = 403, body = "{}",
        headers = {
            ["date"] = "Tue, 14 Nov 2023 22:13:20 GMT",
            ["x-ratelimit-remaining"] = "0", ["x-ratelimit-reset"] = "1700000050",
        },
    } })
    local _, err = GitHub.searchRepositories({ q = "x" })
    check("Date header: wait measured on GitHub's clock (device 30 s behind)",
        GitHub.rateLimitDelay(err, 1700000000 - 30), 51)
    check("Date header: wait measured on GitHub's clock (device 2 min ahead)",
        GitHub.rateLimitDelay(err, 1700000000 + 120), 51)
end
do
    -- No Date header, device behind: the search limit resets every minute, so
    -- never more than a minute's wait for it.
    reset({ {
        code = 403, body = "{}",
        headers = {
            ["x-ratelimit-resource"] = "search",
            ["x-ratelimit-remaining"] = "0", ["x-ratelimit-reset"] = "1700000050",
        },
    } })
    local _, err = GitHub.searchRepositories({ q = "x" })
    check("search limit: never waits past its minute", GitHub.rateLimitDelay(err, 1700000000 - 30), 61)
end
do
    reset({ { code = 200, body = "search", headers = { ["date"] = "Tue, 14 Nov 2023 22:13:20 GMT" } } })
    local parsed = GitHub.searchRepositories({ q = "x" })
    check("search response carries GitHub's time", parsed and parsed.server_time, 1700000000)
end

-- ── A 403 is not always a rate limit ────────────────────────────────────────
do
    reset({ {
        code = 403, body = '{"message":"Resource not accessible"}',
        headers = { ["x-ratelimit-remaining"] = "27", ["x-ratelimit-reset"] = "1700000041" },
    } })
    local _, err = GitHub.searchRepositories({ q = "x" })
    check("403 with requests left: not a rate limit", err and err.is_rate_limit, false)
    check("403 with requests left: nothing to wait for", GitHub.rateLimitDelay(err, 1700000000), nil)
end
do
    -- The secondary limit, without Retry-After: GitHub asks for at least a minute.
    reset({ {
        code = 403, body = '{"message":"You have exceeded a secondary rate limit."}',
        headers = { ["x-ratelimit-remaining"] = "27", ["x-ratelimit-reset"] = "1700000041" },
    } })
    local _, err = GitHub.searchRepositories({ q = "x" })
    check("secondary limit: a rate limit", err and err.is_rate_limit, true)
    check("secondary limit: a minute's wait", GitHub.rateLimitDelay(err, 1700000000), 60)
end

-- ── Stopping during a retry's wait stops the retries ────────────────────────
do
    reset({ { code = 502, body = "{}" }, { code = 502, body = "{}" }, { code = 200, body = "search" } })
    GitHub.wait = function(seconds)
        waits[#waits + 1] = seconds
        return false
    end
    local parsed, err = GitHub.searchRepositories({ q = "x" })
    check("stopped during a retry wait: no further request", #requests, 1)
    check("stopped during a retry wait: reports the failure", parsed == nil and err and err.code, 502)
end

if failures > 0 then
    print(failures .. " FAILED")
    os.exit(1)
end
print("all passed")
