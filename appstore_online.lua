-- appstore_online.lua
-- A guard in front of KOReader's NetworkMgr:runWhenOnline. When Wi-Fi is
-- connected but hostnames do not resolve (KOReader's isOnline test), that call
-- only tries to reconnect and drops its callback without a word, so a refresh
-- or an install just never happens and nothing is logged. Here that case is
-- handed to `on_unreachable` instead; every other case goes to KOReader as
-- before (Wi-Fi off: it turns Wi-Fi on or asks, then runs the callback).
-- `net` is NetworkMgr, passed in so this runs without KOReader in the tests.
local Online = {}

function Online.run(net, callback, on_unreachable)
    if net:isOnline() then
        callback()
    elseif net:isConnected() then
        if on_unreachable then
            on_unreachable()
        end
    else
        net:runWhenOnline(callback)
    end
end

return Online
