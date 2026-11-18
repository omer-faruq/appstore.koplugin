-- Exhaustive GitHub repository search, past the Search API's 1000-result ceiling.
--
-- GitHub hands out at most the first 1000 results of any query (page 11 at
-- per_page=100 is a 422). Two keys narrow a query without losing anything:
--
--   1. Stars, as a cursor. Results come sorted by stars, descending. When a
--      query fills all ten pages, the last repository's star count S is the
--      lowest seen, and the window may have stopped partway through it. S is
--      then collected on its own (step 2) and the query continues as
--      `stars:<lo>..S-1`. Repositories at S come back once more and the
--      caller's de-duplication drops them.
--   2. Creation time, by bisection. A single star count can hold 1000 or more
--      repositories -- the 0-star bucket does -- so it is split by `created:`
--      range, halving down to single seconds if it has to. GitHub cannot sort
--      by creation time, so this is bisection rather than a second cursor.
--
-- Nothing is decided from an upfront probe: the search pages until a short
-- page, and splits only when it actually reaches the ceiling. Cost stays close
-- to one request per hundred repositories however large the result set grows.
--
-- No KOReader dependencies: the page fetch is injected, which keeps this module
-- testable in a plain LuaJIT (tests/appstore_search_test.lua).

local Search = {}

Search.RESULT_LIMIT = 1000
Search.PER_PAGE = 100
-- 2007-10-01T00:00:00Z, before GitHub opened its doors; nothing is older.
Search.ORIGIN_TS = 1191196800

local function starRange(lo, hi)
    if hi then
        return string.format(" stars:%d..%d", lo, hi)
    end
    return string.format(" stars:>=%d", lo)
end

local function isoTime(ts)
    return os.date("!%Y-%m-%dT%H:%M:%SZ", ts)
end

local function starsOf(repo)
    return tonumber(repo and repo.stargazers_count) or 0
end

-- Page through one query, appending every result. Returns
-- `err, capped, last`: `capped` means the query holds more than it was
-- allowed to hand out and must be narrowed. With `stop_over_limit`, a page 1
-- reporting a total at or past the ceiling ends it right there -- the caller
-- splits anyway, so paging on would only fetch what the halves fetch again.
local function fetchWindow(ctx, query, stop_over_limit)
    local per_page = Search.PER_PAGE
    local last
    local page = 1
    while true do
        local response, err = ctx.fetch(query, page, per_page)
        if not response then
            return err
        end
        local items = response.items or {}
        for _, repo in ipairs(items) do
            if type(repo) == "table" then
                ctx.append(repo)
                last = repo
            end
        end
        if #items < per_page then
            return nil, false, last
        end
        if stop_over_limit and page == 1
            and (tonumber(response.total_count) or 0) >= Search.RESULT_LIMIT then
            return nil, true, last
        end
        -- Not trusting total_count here: it is an estimate, and a full last page
        -- is the only reliable sign that something is left past it.
        if page * per_page >= Search.RESULT_LIMIT then
            return nil, true, last
        end
        page = page + 1
    end
end

-- Everything matching `query` created within [from_ts, to_ts], both inclusive.
local function collectByCreated(ctx, query, from_ts, to_ts)
    local windowed = query .. string.format(" created:%s..%s", isoTime(from_ts), isoTime(to_ts))
    local err, capped = fetchWindow(ctx, windowed, true)
    if err or not capped then
        return err
    end
    if to_ts <= from_ts then
        -- A thousand repositories created in one second, at one star count:
        -- nothing left to split on. Keep what GitHub handed out.
        ctx.warn("AppStore search: over the result limit within one second, some results skipped", windowed)
        return nil
    end
    local mid = math.floor((from_ts + to_ts) / 2)
    err = collectByCreated(ctx, query, from_ts, mid)
    if err then
        return err
    end
    return collectByCreated(ctx, query, mid + 1, to_ts)
end

-- Collect every repository matching `query`.
--
-- opts.fetch(query, page, per_page) -> response | nil, err
--     One Search API page. Must ask for sort=stars&order=desc; the star cursor
--     depends on it. `query` already carries the stars:/created: qualifiers.
-- opts.append(repo)       called for every result; repeats are the caller's to drop
-- opts.min_stars          lowest star count to ask for (default 0)
-- opts.now                upper end of the creation range (default os.time())
-- opts.warn(...)          optional logger for results that could not be reached
--
-- Returns nil once everything is collected, or the first fetch error (whatever
-- was appended before it stays appended).
function Search.collect(query, opts)
    local ctx = {
        fetch = opts.fetch,
        append = opts.append,
        warn = opts.warn or function() end,
    }
    local lo = tonumber(opts.min_stars) or 0
    local now = tonumber(opts.now) or os.time()
    local hi -- nil: no upper bound yet
    while not hi or hi >= lo do
        local err, capped, last = fetchWindow(ctx, query .. starRange(lo, hi), false)
        if err or not capped then
            return err
        end
        -- The window stopped somewhere inside the star count `bottom`. That count
        -- is collected on its own -- by creation-time bisection, which pages it
        -- plainly when it is small and splits it at once when it alone is past
        -- the ceiling -- and the cursor continues strictly below it.
        local bottom = starsOf(last)
        -- Clamped: stars can change between pages, and the bound must only ever
        -- shrink or the loop could revisit a range forever.
        if hi and bottom > hi then
            bottom = hi
        end
        err = collectByCreated(ctx, query .. starRange(bottom, bottom), Search.ORIGIN_TS, now)
        if err then
            return err
        end
        hi = bottom - 1
    end
    return nil
end

return Search
