-- Exhaustive GitHub repository search, past the Search API's 1000-result ceiling.
--
-- GitHub hands out at most the first 1000 results of any query (page 11 at
-- per_page=100 is a 422). The Search API is rate-limited per request (30 a minute
-- with a token, 10 without), so what this module minimises is requests: the floor
-- is one per hundred repositories, and it stays close to it however many match.
--
-- A query is cut into `created:` windows, each under the ceiling:
--
--   * First the whole history, as one window. Under the ceiling -- the common
--     case -- it is simply paged, at exactly the floor.
--   * Over it, the history is swept oldest to newest. Each over-limit window met
--     leaves a marker ahead of the cursor: where it ends, and exactly how many
--     results lie before that. A window that fits is taken whole, page 1 being its
--     data rather than a probe; one that overshoots only adds a marker.
--   * Where a window ends is worked out from counts alone: the exact ones at the
--     markers, and the density just behind the cursor, read off the window taken
--     last (every creation time in it is known). Not from the order results come
--     in: GitHub sorts by stars, and the most-starred repositories are the old
--     ones -- in the live .koplugin set, the hundred most-starred have their
--     median at the 14th percentile of creation time.
--
-- Stars play no part: GitHub cannot sort by creation time, but it can count any
-- `created:` range, and ranges go down to the second. 1000 repositories created
-- in the same second for one query is the only thing left out, and GitHub does
-- not create repositories that fast.
--
-- No KOReader dependencies: the page fetch is injected, which keeps this module
-- testable in a plain LuaJIT (tests/appstore_search_test.lua, which also holds
-- the request counts it is held to).

local Search = {}

Search.RESULT_LIMIT = 1000
Search.PER_PAGE = 100
-- What a window is aimed at. The margin under the ceiling absorbs the estimate's
-- error: an overshoot costs a request, an undershoot a fuller last page.
Search.AIM = 900
-- 2007-10-01T00:00:00Z, before GitHub opened its doors; nothing is older.
Search.ORIGIN_TS = 1191196800

-- Seconds since the epoch for GitHub's "2024-01-31T10:00:00Z". Computed rather
-- than handed to os.time, which would read it as local time.
local function parseIso(s)
    if type(s) ~= "string" then
        return nil
    end
    local y, m, d, hh, mm, ss = s:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
    if not y then
        return nil
    end
    y, m, d = tonumber(y), tonumber(m), tonumber(d)
    if m <= 2 then
        y = y - 1
    end
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local doy = math.floor((153 * ((m + 9) % 12) + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    local days = era * 146097 + doe - 719468
    return days * 86400 + tonumber(hh) * 3600 + tonumber(mm) * 60 + tonumber(ss)
end
Search.parseIso = parseIso

local function isoTime(ts)
    return os.date("!%Y-%m-%dT%H:%M:%SZ", ts)
end

local function windowQuery(query, from_ts, to_ts)
    return query .. string.format(" created:%s..%s", isoTime(from_ts), isoTime(to_ts))
end

-- Page through everything created in [from_ts, to_ts]. Returns
-- `err, over, total, times`: `over` means the window holds 1000 or more and
-- cannot be paged whole -- known from page 1's count, so it costs that one
-- request (its results are appended all the same). Otherwise `times` are the
-- creation times of everything in it.
local function fetchWindow(ctx, query, from_ts, to_ts)
    local windowed = windowQuery(query, from_ts, to_ts)
    local per_page = Search.PER_PAGE
    local times = {}
    local page = 1
    while true do
        local response, err = ctx.fetch(windowed, page, per_page)
        if not response then
            return err
        end
        local total = tonumber(response.total_count) or 0
        local items = response.items or {}
        for _, repo in ipairs(items) do
            if type(repo) == "table" then
                ctx.append(repo)
                times[#times + 1] = parseIso(repo.created_at)
            end
        end
        -- Past page 1 the window was counted under the ceiling; ten full pages anyway
        -- means it grew while being paged, and it is cut like any over-limit window.
        if (page == 1 and total >= Search.RESULT_LIMIT)
            or (#items == per_page and page * per_page >= Search.RESULT_LIMIT) then
            return nil, true, math.max(total, Search.RESULT_LIMIT)
        end
        if #items < per_page or page * per_page >= total then
            return nil, false, total, times
        end
        page = page + 1
    end
end

-- Results per second just before `to_ts`, from the creation times of a window
-- taken whole that ends there: the newer half of them, over the time they span.
local function densityBefore(times, from_ts, to_ts)
    local n = #times
    if n < 20 then
        return n / math.max(1, to_ts - from_ts + 1)
    end
    table.sort(times)
    local mid = math.floor(n / 2)
    return (n - mid) / math.max(1, to_ts - times[mid] + 1)
end

-- A thousand results created within one second: nothing left to cut on. Takes
-- the thousand GitHub hands out.
local function takeOneSecond(ctx, query, ts)
    ctx.warn("AppStore search: over the result limit within one second, some results skipped",
        query, isoTime(ts))
    local windowed = windowQuery(query, ts, ts)
    for page = 1, Search.RESULT_LIMIT / Search.PER_PAGE do
        local response, err = ctx.fetch(windowed, page, Search.PER_PAGE)
        if not response then
            return err
        end
        local items = response.items or {}
        for _, repo in ipairs(items) do
            ctx.append(repo)
        end
        if #items < Search.PER_PAGE then
            break
        end
    end
end

-- Density along a stretch of `length` seconds holding `count` results, taken to
-- change linearly from `start` (results per second at its beginning; nil when
-- unknown, for an even spread). Returns the densities at both ends, adjusted so
-- that neither is negative and the stretch still holds exactly `count`.
local function linearDensity(count, length, start)
    local avg = count / length
    local a = start or avg
    local b = 2 * avg - a
    if b < 0 then
        a, b = 2 * avg, 0
    end
    return a, b
end

-- Seconds into a stretch (densities `a` to `b` over `length`) at which `need`
-- results have gone by: solves a*s + (b-a)*s^2/(2*length) = need.
local function secondsFor(need, a, b, length)
    local k = (b - a) / (2 * length)
    local disc = a * a + 4 * k * need
    if disc < 0 then
        -- A falling density that never adds up to `need` inside the stretch.
        return length
    end
    -- The root (-a + sqrt(disc)) / (2k), rewritten so that it neither divides by a
    -- slope that is next to nothing -- densities are per second, slopes per second
    -- squared -- nor loses its digits to cancellation.
    local denom = a + math.sqrt(disc)
    if denom <= 0 then
        return length
    end
    return 2 * need / denom
end

-- Where to end a window from the cursor `from_ts`, so that it holds about AIM.
-- `base` is the furthest marker counting under the ceiling (or nil), `outer` the
-- next one out, `density` the results per second just behind the cursor (or nil).
local function chooseCut(from_ts, base, outer, density)
    local base_stop = base and base.stop or (from_ts - 1)
    local base_count = base and base.count or 0
    -- Carry the density from the cursor to base_stop across the counted stretch.
    local start = density
    if base then
        local _, b = linearDensity(base_count, math.max(1, base_stop - from_ts + 1), density)
        start = density and b or nil
    end
    local length = outer.stop - base_stop
    local a, b = linearDensity(outer.count - base_count, length, start)
    local s = secondsFor(Search.AIM - base_count, a, b, length)
    local cut = base_stop + math.floor(s)
    return math.max(base_stop + 1, math.min(cut, outer.stop - 1))
end

-- Collect [from_ts, to_ts], which holds `total` >= RESULT_LIMIT results.
--
-- The sweep keeps markers ahead of its cursor, one per over-limit window met:
-- `stop`, and `count` -- exactly how many results lie between the cursor and
-- `stop`, kept current as windows are taken. Each window runs from the cursor to
-- the furthest marker still counting under the ceiling when that holds AIM or
-- more -- an exact fit, nothing estimated -- and otherwise reaches past it by an
-- estimate into the next marker out. A window that overshoots only adds a marker:
-- the cursor never stops at one, so no stretch is left with a sliver of a window
-- of its own.
local function sweep(ctx, query, from_ts, to_ts, total)
    local markers = { { stop = to_ts, count = total } }
    local density -- results per second just behind the cursor, once a window is taken
    while #markers > 0 do
        -- Ordered by stop, so the counts only grow outwards.
        local j = 0
        while j < #markers and markers[j + 1].count < Search.RESULT_LIMIT do
            j = j + 1
        end
        local base, outer = markers[j], markers[j + 1]
        local base_stop = base and base.stop or (from_ts - 1)
        local base_count = base and base.count or 0

        local cut, err, over, count, times
        if not outer or base_count >= Search.AIM or outer.stop - base_stop <= 1 then
            if base then
                cut = base_stop
                if base_count > 0 then
                    err, over, count, times = fetchWindow(ctx, query, from_ts, cut)
                else
                    -- Counted empty; nothing created before `now` turns up there since.
                    count = 0
                end
            else
                -- `outer` is the single second at the cursor, over the limit.
                cut = outer.stop
                err = takeOneSecond(ctx, query, cut)
                count = outer.count
            end
        else
            cut = chooseCut(from_ts, base, outer, density)
            err, over, count, times = fetchWindow(ctx, query, from_ts, cut)
        end
        if err then
            return err
        end

        if over then
            if base and cut == base_stop then
                -- Counted under the ceiling once, over it now: it grew meanwhile.
                base.count = count
            else
                -- Strictly between base and outer, so the ordering holds; clamped so
                -- that a count which moved meanwhile cannot break it.
                table.insert(markers, j + 1, {
                    stop = cut,
                    count = math.min(math.max(count, base_count), outer.count),
                })
            end
        else
            if times and #times > 0 then
                density = densityBefore(times, from_ts, cut)
            end
            from_ts = cut + 1
            local kept = {}
            for _, m in ipairs(markers) do
                if m.stop > cut then
                    m.count = math.max(0, m.count - count)
                    kept[#kept + 1] = m
                end
            end
            markers = kept
        end
    end
    return nil
end

-- Collect every repository matching `query`.
--
-- opts.fetch(query, page, per_page) -> response | nil, err
--     One Search API page. `query` already carries the created: qualifier; the
--     sort order does not matter to this module.
-- opts.append(repo)       called for every result; repeats are the caller's to drop
-- opts.min_stars          lowest star count to ask for (default 0, no qualifier)
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
    local min_stars = tonumber(opts.min_stars) or 0
    if min_stars > 0 then
        query = query .. string.format(" stars:>=%d", min_stars)
    end
    local now = tonumber(opts.now) or os.time()
    local err, over, total = fetchWindow(ctx, query, Search.ORIGIN_TS, now)
    if err or not over then
        return err
    end
    return sweep(ctx, query, Search.ORIGIN_TS, now, total)
end

return Search
