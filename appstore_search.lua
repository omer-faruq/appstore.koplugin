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
-- A window whose pages do not add up is fetched again in pieces aimed at this many
-- results: one page each, with room for what the first pass missed (see fetchRange).
Search.PIECE = 90
-- How many times a window is cut that way before what came back is taken as it is.
Search.MAX_DEPTH = 6
-- What fetching a window in pieces may cost, on top of paging it once: this many times
-- its pages, plus a few. Past that, what came back is taken (and the search reported
-- partial) rather than a GitHub that keeps misbehaving costing without end.
Search.PIECE_BUDGET = 4
-- How many times "now" may be pushed out (see sweep): doubling from a day, far more
-- than GitHub's whole history needs.
Search.MAX_PUSHES = 24

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

-- `to_ts` nil: no upper end. The newest window of a search is left open rather
-- than closed at "now": an e-reader's clock is often wrong, and a closed window
-- would quietly leave out everything created after the time it believes it is.
local function windowQuery(query, from_ts, to_ts)
    if not to_ts then
        return query .. string.format(" created:>=%s", isoTime(from_ts))
    end
    return query .. string.format(" created:%s..%s", isoTime(from_ts), isoTime(to_ts))
end

-- One response's results, appended. Returns how many of them this pass had not
-- seen before (`seen`, keyed by id); their creation times go to `times`. The newest
-- creation time seen anywhere is kept in ctx.newest: evidence of where "now" is.
local function takeItems(ctx, items, seen, times)
    local fresh = 0
    for _, repo in ipairs(items) do
        if type(repo) == "table" then
            ctx.append(repo)
            local t = parseIso(repo.created_at)
            if t and t > (ctx.newest or 0) then
                ctx.newest = t
            end
            local key = repo.id or repo.full_name
            if key == nil or not seen[key] then
                if key ~= nil then
                    seen[key] = true
                end
                fresh = fresh + 1
                if t then
                    times[#times + 1] = t
                end
            end
        end
    end
    return fresh
end

-- Page through `windowed` once. Returns `err` or `nil, r`: `r.over` when page 1
-- counts 1000 or more (only page 1 is taken then), or ten full pages came back
-- anyway (the window grew while being paged); otherwise `r.total` (GitHub's count),
-- `r.short` when the pages did not add up to it or GitHub flagged them
-- `incomplete_results`, and `r.got`, how many distinct results came back.
--
-- Short is measured against the highest count GitHub gave during the pass: a
-- repository deleted after it was seen lowers the count as much as the one it
-- pushed past unseen, so only the count from before the change tells.
local function pageOnce(ctx, windowed, seen, times)
    local per_page = Search.PER_PAGE
    local got, most, total, incomplete = 0, 0, 0, false
    local page = 1
    while true do
        local response, err = ctx.fetch(windowed, page, per_page)
        if not response then
            return err
        end
        -- GitHub's time when the search began. Not the latest response's: that keeps
        -- moving, and the sweep's limit on "now" would move with it (see sweep).
        ctx.server_time = ctx.server_time or tonumber(response.server_time)
        total = tonumber(response.total_count) or 0
        most = math.max(most, total)
        incomplete = incomplete or response.incomplete_results == true
        local items = response.items or {}
        got = got + takeItems(ctx, items, seen, times)
        if (page == 1 and total >= Search.RESULT_LIMIT)
            or (#items == per_page and page * per_page >= Search.RESULT_LIMIT) then
            return nil, { over = true, total = math.max(total, Search.RESULT_LIMIT) }
        end
        if #items < per_page or page * per_page >= total then
            break
        end
        page = page + 1
    end
    return nil, { total = total, got = got, incomplete = incomplete,
        short = incomplete or got < most }
end

-- Where to cut [from_ts, to_ts] (`open`: no upper end, `to_ts` only a guide) into
-- pieces of about PIECE results, from the creation times seen in it; halved when
-- they give nothing to cut on. When far fewer came back than GitHub counted (a
-- short page ended the pass early), they say little about where the rest are, and
-- the range is cut evenly in time into as many pieces as the count needs instead.
-- Every stop lies inside the range and leaves a non-empty piece on both sides, so
-- each piece is strictly smaller. Nil when a range cannot be cut at all (a single
-- second).
local function pieceStops(times, from_ts, to_ts, open, total)
    table.sort(times)
    local hi = to_ts
    if open then
        hi = math.max(to_ts, times[#times] or to_ts)
    end
    local last_stop = open and hi or (to_ts - 1)
    local stops = {}
    local function add(stop)
        if stop >= from_ts and stop <= last_stop and stop > (stops[#stops] or (from_ts - 1)) then
            stops[#stops + 1] = stop
        end
    end
    if #times >= 0.8 * total then
        for i = Search.PIECE, #times - 1, Search.PIECE do
            add(times[i])
        end
    else
        -- A window paged whole holds under 1000; a count above that is GitHub's, not the
    -- window's, and must not turn into thousands of pieces.
    local k = math.ceil(math.min(total, Search.RESULT_LIMIT) / Search.PIECE)
        for i = 1, k - 1 do
            add(from_ts + math.floor(i * (hi - from_ts + 1) / k) - 1)
        end
    end
    if #stops == 0 then
        if hi <= from_ts and not open then
            return nil
        end
        if hi < from_ts then
            return nil
        end
        stops[1] = from_ts + math.floor((hi - from_ts) / 2)
    end
    return stops
end

-- A thousand results created within one second: nothing left to cut on. Takes
-- the thousand GitHub hands out.
local function takeFirstThousand(ctx, windowed)
    ctx.partial = true
    for page = 1, Search.RESULT_LIMIT / Search.PER_PAGE do
        local response, err = ctx.fetch(windowed, page, Search.PER_PAGE)
        if not response then
            return err
        end
        local items = response.items or {}
        takeItems(ctx, items, {}, {})
        if #items < Search.PER_PAGE then
            break
        end
    end
end

local function takeOneSecond(ctx, query, ts)
    ctx.warn("AppStore search: over the result limit within one second, some results skipped",
        query, isoTime(ts))
    return takeFirstThousand(ctx, windowQuery(query, ts, ts))
end

-- Fetch everything created in [from_ts, to_ts] (`open`: from_ts on, `to_ts` only a
-- guide for cutting). Returns `err, over, count, times`: `over` (only at depth 0,
-- for the sweep to cut) means the window holds 1000 or more and cannot be paged
-- whole -- known from page 1's count, so it costs that one request (its results
-- are appended all the same). Otherwise `count` is GitHub's count of the window
-- and `times` the creation times of everything in it.
--
-- GitHub's answers move while they are paged. Results come sorted by stars: a
-- repository deleted or starred between two pages shifts the rest and one slips
-- past unseen, and repositories with equal stars have no order of their own to
-- keep from one request to the next. A search that ran out of time on GitHub's
-- side comes back flagged `incomplete_results`. Paging the window again would only
-- move the same way, so a window that does not add up is fetched again in pieces
-- of about one page each, cut where its creation times say: a single page cannot
-- shift under itself. A one-page piece flagged incomplete is asked once more; one
-- that still does not add up is taken as GitHub gives it, with a warning, and the
-- search reported partial (ctx.partial): a count GitHub never makes good, or a
-- flag it keeps raising, must neither fail every refresh for good nor pass for a
-- complete result. So is a window whose pieces would cost more than PIECE_BUDGET.
local function fetchRange(ctx, query, from_ts, to_ts, open, depth)
    local windowed = windowQuery(query, from_ts, (not open) and to_ts or nil)
    local seen, times = {}, {}
    local err, r = pageOnce(ctx, windowed, seen, times)
    if err then
        return err
    end
    if r.over and depth == 0 then
        return nil, true, r.total
    end
    if not r.over and not r.short then
        return nil, false, r.total, times
    end
    if not r.over and r.total <= Search.PER_PAGE then
        local got = r.got
        if r.incomplete then
            local err2, r2 = pageOnce(ctx, windowed, seen, times)
            if err2 then
                return err2
            end
            got = got + (r2.over and 0 or r2.got)
            r = r2.over and r or r2
        end
        if got < r.total or r.incomplete then
            ctx.partial = true
            ctx.warn("AppStore search: GitHub's count does not add up, taking what it gives",
                windowed, got, r.total, r.incomplete and "incomplete_results" or "")
        end
        return nil, false, r.total, times
    end
    if depth == 0 then
        ctx.budget_end = ctx.calls
            + Search.PIECE_BUDGET * math.ceil(math.min(r.total, Search.RESULT_LIMIT) / Search.PER_PAGE) + 10
    end
    local stops = depth < Search.MAX_DEPTH and ctx.calls < ctx.budget_end
        and pieceStops(times, from_ts, to_ts, open, r.total)
    if not stops then
        if r.over then
            -- Cut short by depth or budget rather than down to one second: whatever the
            -- range, the thousand GitHub hands out, never just its first second.
            if not open and from_ts >= to_ts then
                err = takeOneSecond(ctx, query, from_ts)
            else
                err = takeFirstThousand(ctx, windowed)
            end
            if err then
                return err
            end
        end
        ctx.partial = true
        ctx.warn("AppStore search: window cannot be cut further, taking what GitHub gives", windowed)
        return nil, false, r.total, times
    end
    ctx.warn("AppStore search: window came back short, fetching it in pieces", windowed, #stops + 1)
    local count, all = 0, {}
    local lo = from_ts
    for i = 1, #stops + 1 do
        local last = i > #stops
        local hi = last and to_ts or stops[i]
        local perr, _, n, t = fetchRange(ctx, query, lo, math.max(hi, lo), last and open, depth + 1)
        if perr then
            return perr
        end
        count = count + n
        for _, x in ipairs(t) do
            all[#all + 1] = x
        end
        lo = hi + 1
    end
    return nil, false, count, all
end

local function fetchWindow(ctx, query, from_ts, to_ts, open)
    return fetchRange(ctx, query, from_ts, to_ts, open, 0)
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
--
-- `to_ts` is the present as far as it is known. The last marker stands for
-- everything from the cursor on, and a window ending at it is left open; should
-- what lies past it still be over the ceiling once the cursor gets there (a clock
-- far behind), the present is pushed out, doubling -- but only as far as there is
-- evidence of: GitHub's time when the search began, or the newest repository seen
-- (a look at the open window's page 1 adds to that when it runs out), and never
-- more than MAX_PUSHES times. With nothing more to go on, the counts disagree with the windows: the
-- open rest is taken as far as GitHub hands it out and the search reported
-- partial, rather than walking windows into the empty future.
local function sweep(ctx, query, from_ts, to_ts, total)
    local markers = { { stop = to_ts, count = total } }
    local density -- results per second just behind the cursor, once a window is taken
    local start_ts = from_ts
    local pushes = 0
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
        if outer and outer.stop == to_ts and outer.stop - base_stop <= 1 then
            -- Over the ceiling past the present: the present was not the present.
            local limit = math.max(ctx.server_time or 0, ctx.newest or 0) + 86400
            if to_ts >= limit and pushes < Search.MAX_PUSHES then
                err = pageOnce(ctx, windowQuery(query, from_ts, nil), {}, {})
                limit = math.max(ctx.server_time or 0, ctx.newest or 0) + 86400
            end
            if err then
                return err
            end
            if to_ts >= limit or pushes >= Search.MAX_PUSHES then
                -- Nothing more to go on: GitHub's counts and its results disagree past here.
                -- The open rest is taken as far as GitHub hands it out.
                ctx.warn("AppStore search: counts do not match results past", isoTime(from_ts), query)
                return takeFirstThousand(ctx, windowQuery(query, from_ts, nil))
            end
            pushes = pushes + 1
            to_ts = math.min(to_ts + math.max(86400, to_ts - start_ts), limit)
            outer.stop = to_ts
        elseif not outer or base_count >= Search.AIM or outer.stop - base_stop <= 1 then
            if base then
                -- A count of 0 is not taken on trust: it is worked out by subtraction,
                -- and older repositories can start matching while the sweep runs.
                cut = base_stop
                err, over, count, times = fetchWindow(ctx, query, from_ts, cut, cut == to_ts)
            else
                -- `outer` is the single second at the cursor, over the limit.
                cut = outer.stop
                err = takeOneSecond(ctx, query, cut)
                count = outer.count
            end
        else
            cut = chooseCut(from_ts, base, outer, density)
            err, over, count, times = fetchWindow(ctx, query, from_ts, cut, false)
        end
        if err then
            return err
        end

        if not cut then
            -- The present was moved; nothing fetched.
            count = nil
        elseif over then
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
-- opts.now                the present, when GitHub's responses do not carry
--                         `server_time` (default os.time()); only a guide to where
--                         windows are cut, never an end to what is searched
-- opts.warn(...)          optional logger for results that could not be reached
--
-- Returns the first fetch error (whatever was appended before it stays appended),
-- or `nil, partial`: `partial` is true when GitHub left something out that could
-- not be made good -- its count never added up, it kept flagging results
-- incomplete, more than 1000 were created in one second -- so that the caller can
-- keep what it had rather than take this for the whole list.
function Search.collect(query, opts)
    local ctx = {
        append = opts.append,
        warn = opts.warn or function() end,
        calls = 0,
        budget_end = 0,
    }
    function ctx.fetch(...)
        ctx.calls = ctx.calls + 1
        return opts.fetch(...)
    end
    local min_stars = tonumber(opts.min_stars) or 0
    if min_stars > 0 then
        query = query .. string.format(" stars:>=%d", min_stars)
    end
    local now = tonumber(opts.now) or os.time()
    local err, over, total = fetchWindow(ctx, query, Search.ORIGIN_TS, math.max(now, Search.ORIGIN_TS + 1), true)
    if not err and over then
        now = ctx.server_time or now
        err = sweep(ctx, query, Search.ORIGIN_TS, math.max(now, Search.ORIGIN_TS + 1), total)
    end
    if err then
        return err
    end
    return nil, ctx.partial == true
end

Search._pieceStops = pieceStops -- for the tests

return Search
