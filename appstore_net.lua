--[[--
HTTP requests with a deadline on them.

`socketutil`'s timeouts are global: set, request, reset. Should the request throw in between,
the reset never runs and the rest of KOReader keeps waiting as long as we asked to. Here the
request goes through pcall, so the reset happens whatever the outcome.

The sink is built here rather than by the caller because socketutil's sinks read the deadline
when they are created, which has to be after `set_timeout`.

    local body_parts = {}
    local code, _, status = Net.requestToTable(request, body_parts)
    local code, headers, status = Net.requestToFile(request, file, socketutil.FILE_BLOCK_TIMEOUT,
        socketutil.FILE_TOTAL_TIMEOUT)

`code` is nil only when the request threw, and the error message takes the place of the status
line. A timeout arrives as a string where `code` would be. Callers pass either on, so the
reason reaches their log instead of turning into a bare nil.
]]

local http = require("socket.http")
local socketutil = require("socketutil")
local logger = require("logger")

local Net = {}

local function perform(request, make_sink, block_timeout, total_timeout)
    socketutil:set_timeout(block_timeout or socketutil.LARGE_BLOCK_TIMEOUT,
        total_timeout or socketutil.LARGE_TOTAL_TIMEOUT)
    request.sink = make_sink()
    local ok, result, code, headers, status = pcall(http.request, request)
    socketutil:reset_timeout()
    if not ok then
        logger.warn("appstore: request failed:", request.url, result)
        -- The reason goes where a status line would: callers already read it.
        return nil, nil, result
    end
    return code, headers, status
end

--- Collect the response body into `response_parts`, to be concatenated by the caller.
function Net.requestToTable(request, response_parts, block_timeout, total_timeout)
    return perform(request, function()
        return socketutil.table_sink(response_parts)
    end, block_timeout, total_timeout)
end

--- Write the response body to an open file.
function Net.requestToFile(request, file, block_timeout, total_timeout)
    return perform(request, function()
        return socketutil.file_sink(file)
    end, block_timeout, total_timeout)
end

return Net
