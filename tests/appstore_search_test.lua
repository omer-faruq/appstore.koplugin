-- appstore_search_test.lua
-- Run with a plain LuaJIT, from the plugin folder or from a KOReader tree:
--   luajit tests/appstore_search_test.lua
--   ./luajit plugins/appstore.koplugin/tests/appstore_search_test.lua
--
-- appstore_search has no KOReader dependencies: the page fetch is handed in, so
-- these tests drive it against a fake GitHub search that enforces the real
-- 1000-result ceiling (422 past it) and the stars:/created: qualifiers, and
-- answers sort=stars the way GitHub does -- which matters, since the
-- most-starred repositories are the old ones.
--
-- The request counts asserted below are the module's measured cost, with a
-- little slack: a change that makes the search markedly more expensive fails.
package.path = "plugins/appstore.koplugin/?.lua;./?.lua;" .. package.path

local Search = require("appstore_search")

local failures = 0
local function check(label, got, expected)
    if got == expected then
        print("PASS", label)
    else
        failures = failures + 1
        print("FAIL", label, "expected=", tostring(expected), "got=", tostring(got))
    end
end

-- ── Fake GitHub search ──────────────────────────────────────────────────────

-- Seconds since the epoch for a UTC civil date (days-from-civil, no os.time
-- so the local timezone cannot leak in).
local function utc(y, m, d, hh, mm, ss)
    y = (m <= 2) and (y - 1) or y
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local mp = (m + 9) % 12
    local doy = math.floor((153 * mp + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    local days = era * 146097 + doe - 719468
    return days * 86400 + (hh or 0) * 3600 + (mm or 0) * 60 + (ss or 0)
end

local function parseIso(s)
    local y, m, d, hh, mm, ss = s:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)Z$")
    if y then
        return utc(tonumber(y), tonumber(m), tonumber(d), tonumber(hh), tonumber(mm), tonumber(ss))
    end
    y, m, d = s:match("^(%d+)-(%d+)-(%d+)$")
    assert(y, "fake GitHub: unparsable date " .. s)
    return utc(tonumber(y), tonumber(m), tonumber(d))
end

-- Repos are kept sorted the way GitHub answers sort=stars&order=desc: by stars,
-- ties in an order that has nothing to do with creation time.
local function newFakeGitHub(repos)
    for _, r in ipairs(repos) do
        r.created_at = r.created_at or os.date("!%Y-%m-%dT%H:%M:%SZ", r.created_ts)
    end
    table.sort(repos, function(a, b)
        if a.stargazers_count ~= b.stargazers_count then
            return a.stargazers_count > b.stargazers_count
        end
        return a.tie < b.tie
    end)
    local gh = { calls = 0, rejected = 0, queries = {} }
    function gh.fetch(query, page, per_page)
        gh.calls = gh.calls + 1
        gh.queries[#gh.queries + 1] = query
        local s_lo, s_hi = 0, math.huge
        for q in query:gmatch("stars:(%S+)") do
            local a, b = q:match("^(%d+)%.%.(%d+)$")
            if a then
                s_lo, s_hi = math.max(s_lo, tonumber(a)), math.min(s_hi, tonumber(b))
            elseif q:match("^>=%d+$") then
                s_lo = math.max(s_lo, tonumber(q:sub(3)))
            else
                local n = assert(tonumber(q), "fake GitHub: unsupported stars:" .. q)
                s_lo, s_hi = math.max(s_lo, n), math.min(s_hi, n)
            end
        end
        local c_lo, c_hi = -math.huge, math.huge
        for a, b in query:gmatch("created:(%S+)%.%.(%S+)") do
            c_lo, c_hi = math.max(c_lo, parseIso(a)), math.min(c_hi, parseIso(b))
        end
        if (page - 1) * per_page >= 1000 then
            gh.rejected = gh.rejected + 1
            return nil, { code = 422, body = "Only the first 1000 search results are available" }
        end
        local first, last = (page - 1) * per_page + 1, page * per_page
        local items, total = {}, 0
        for _, r in ipairs(repos) do
            if r.stargazers_count >= s_lo and r.stargazers_count <= s_hi
                and r.created_ts >= c_lo and r.created_ts <= c_hi then
                total = total + 1
                if total >= first and total <= last then
                    items[#items + 1] = r
                end
            end
        end
        return { total_count = total, items = items }
    end
    return gh
end

-- Deterministic pseudo-random numbers, so a failure reproduces. LuaJIT's own
-- generator (Tausworthe) is seedable and repeatable; a hand-rolled LCG
-- correlated consecutive draws -- one repository's stars with its creation
-- time -- which is a bias GitHub's data does not have.
local function rng(seed)
    math.randomseed(seed)
    return function(n)
        return math.random(0, n - 1)
    end
end

local FROM = utc(2008, 4, 1)
local NOW = utc(2026, 11, 18, 12, 0, 0)

-- `zero_share` of the repos get 0 stars, the rest a long-tailed count.
-- `skew` 1 spreads creation evenly over the years; higher piles it up towards
-- the present, the way the KOReader ecosystem actually grew.
-- `old_stars`: older repositories hold more of the stars, as they do on GitHub,
-- so page 1 (the most-starred) leans towards the older end of a window.
local function makeRepos(n, zero_share, seed, skew, old_stars)
    local rand = rng(seed or 1)
    skew = skew or 1
    local repos = {}
    for i = 1, n do
        local stars = 0
        if rand(1000) >= zero_share * 1000 then
            stars = 1 + math.floor(2 ^ (rand(1400) / 100)) -- 1 .. ~16000, most of them small
        end
        local age = (rand(1000000) / 1000000) ^ skew
        if old_stars then
            stars = math.floor(stars * 4 * age)
        end
        repos[i] = {
            id = i,
            full_name = "owner" .. i .. "/repo.koplugin",
            stargazers_count = stars,
            created_ts = NOW - math.floor((NOW - FROM) * age),
            tie = rand(2147483647),
        }
    end
    return repos
end

-- The live snapshot in tests/fixtures: every in:name ".koplugin" repository
-- with its real creation time and star count, for request counts measured on
-- the distribution that matters rather than a made-up one.
local function loadSnapshot(branch)
    local path
    for _, candidate in ipairs({
        "tests/fixtures/koplugin_search_snapshot.txt",
        "plugins/appstore.koplugin/tests/fixtures/koplugin_search_snapshot.txt",
    }) do
        local f = io.open(candidate, "rb")
        if f then f:close(); path = candidate; break end
    end
    assert(path, "snapshot fixture not found")
    local repos = {}
    local tie = rng(99)
    for line in io.lines(path) do
        local b, created, stars = line:match("^(%a+) (%d+) (%d+)")
        if b == branch then
            repos[#repos + 1] = {
                id = #repos + 1,
                stargazers_count = tonumber(stars),
                created_ts = tonumber(created),
                tie = tie(2147483647),
            }
        end
    end
    assert(#repos > 1000, "snapshot fixture has too few " .. branch .. " rows")
    return repos
end

local function run(repos, opts)
    opts = opts or {}
    local gh = newFakeGitHub(repos)
    local seen, unique = {}, 0
    local warnings = 0
    local err = Search.collect("in:name \".koplugin\"", {
        fetch = opts.fetch and opts.fetch(gh) or gh.fetch,
        append = function(repo)
            if not seen[repo.id] then
                seen[repo.id] = true
                unique = unique + 1
            end
        end,
        min_stars = opts.min_stars,
        now = NOW,
        warn = function() warnings = warnings + 1 end,
    })
    return { err = err, unique = unique, seen = seen, gh = gh, warnings = warnings }
end

local function expectedCount(repos, min_stars)
    local n = 0
    for _, r in ipairs(repos) do
        if r.stargazers_count >= (min_stars or 0) then n = n + 1 end
    end
    return n
end

-- ── Under the ceiling: plain pagination ─────────────────────────────────────
do
    local repos = makeRepos(250, 0.3, 11)
    local r = run(repos)
    check("250 repos: no error", r.err, nil)
    check("250 repos: all collected", r.unique, 250)
    check("250 repos: three pages, no extra queries", r.gh.calls, 3)
    check("250 repos: never asked past 1000", r.gh.rejected, 0)
end

-- ── Exactly at the ceiling ──────────────────────────────────────────────────
do
    local repos = makeRepos(1000, 0.3, 12)
    local r = run(repos)
    check("1000 repos: no error", r.err, nil)
    check("1000 repos: all collected", r.unique, 1000)
    check("1000 repos: never asked past 1000", r.gh.rejected, 0)
end

-- ── Just past the ceiling (the PR #38 report: 1076 .koplugin repos) ─────────
do
    local repos = makeRepos(1076, 0.42, 13)
    local r = run(repos)
    check("1076 repos: no error", r.err, nil)
    check("1076 repos: all collected", r.unique, 1076)
    check("1076 repos: never asked past 1000", r.gh.rejected, 0)
end

-- ── Far past it, with a 0-star bucket that alone exceeds the ceiling ────────
do
    local repos = makeRepos(5000, 0.5, 14)
    local r = run(repos)
    check("5000 repos: no error", r.err, nil)
    check("5000 repos: all collected", r.unique, 5000)
    check("5000 repos: never asked past 1000", r.gh.rejected, 0)
end

-- ── The long run: 100,000 repos, 60% of them at 0 stars ─────────────────────
do
    local repos = makeRepos(100000, 0.6, 15)
    local clock = os.clock()
    local r = run(repos)
    check("100k repos: no error", r.err, nil)
    check("100k repos: all collected", r.unique, 100000)
    check("100k repos: never asked past 1000", r.gh.rejected, 0)
    -- 1000 pages is the floor; over-limit windows and each window's partly
    -- filled last page cost a little on top.
    check("100k repos: under 1080 requests (" .. r.gh.calls .. ")", r.gh.calls < 1080, true)
    print(string.format("      100k run: %d requests, %.1f s", r.gh.calls, os.clock() - clock))
end

-- ── Request cost: how close to one request per hundred repositories ─────────
-- Search is rate-limited per request (30/min with a token, 10 without), so the
-- request count is the cost that matters. ceil(n/100) is the floor.
local function costCase(label, repos, limit, min_stars)
    local r = run(repos, { min_stars = min_stars })
    local want = expectedCount(repos, min_stars)
    check(label .. ": all collected", r.unique, want)
    check(label .. ": never asked past 1000", r.gh.rejected, 0)
    check(string.format("%s: at most %d requests (floor %d, took %d)", label, limit,
        math.ceil(want / 100), r.gh.calls), r.gh.calls <= limit, true)
end

costCase("snapshot non-fork", loadSnapshot("nonfork"), 13)
costCase("snapshot forks incl. 0-star", loadSnapshot("fork"), 17)
costCase("snapshot forks, starred only", loadSnapshot("fork"), 2, 1)
costCase("100k skewed to recent years", makeRepos(100000, 0.6, 21, 3), 1085)
costCase("20k evenly spread", makeRepos(20000, 0.5, 22, 1), 216)
costCase("20k skewed, stars with the old", makeRepos(20000, 0.5, 24, 3, true), 222)

-- ── Every repo with the same star count ─────────────────────────────────────
do
    local repos = makeRepos(3000, 1.0, 16)
    local r = run(repos)
    check("3000 repos all at 0 stars: all collected", r.unique, 3000)
    check("3000 repos all at 0 stars: never asked past 1000", r.gh.rejected, 0)
end

-- ── min_stars keeps lower counts out of the query itself ────────────────────
do
    local repos = makeRepos(3000, 0.5, 17)
    local r = run(repos, { min_stars = 1 })
    check("min_stars=1: no error", r.err, nil)
    check("min_stars=1: every starred repo collected", r.unique, expectedCount(repos, 1))
    local zero_seen = false
    for _, repo in ipairs(repos) do
        if repo.stargazers_count == 0 and r.seen[repo.id] then zero_seen = true end
    end
    check("min_stars=1: no 0-star repo fetched", zero_seen, false)
end

-- ── More than 1000 created in the very same second, same stars ─────────────
-- Nothing left to split on: take the 1000 GitHub hands out, warn, and finish.
do
    local repos = {}
    for i = 1, 1500 do
        repos[i] = { id = i, stargazers_count = 0, created_ts = utc(2024, 1, 1, 10, 0, 0), tie = i }
    end
    local r = run(repos)
    check("1500 in one second: no error", r.err, nil)
    check("1500 in one second: the reachable 1000 collected", r.unique, 1000)
    check("1500 in one second: warned", r.warnings > 0, true)
    check("1500 in one second: never asked past 1000", r.gh.rejected, 0)
end

-- ── A failed request stops the search and is handed back ────────────────────
do
    local repos = makeRepos(2500, 0.3, 18)
    local failing = { code = 502, body = "bad gateway" }
    local r = run(repos, {
        fetch = function(gh)
            return function(query, page, per_page)
                if gh.calls == 4 then
                    gh.calls = gh.calls + 1
                    return nil, failing
                end
                return gh.fetch(query, page, per_page)
            end
        end,
    })
    check("failed request: error handed back", r.err, failing)
    check("failed request: stopped right there", r.gh.calls, 5)
end

if failures > 0 then
    print(failures .. " FAILED")
    os.exit(1)
end
print("all passed")
