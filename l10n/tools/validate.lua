-- Validate a plugin l10n table against the canonical English key set.
-- Usage: luajit validate.lua <canon.lua> <lang.lua>
local canon = dofile(arg[1])
local tbl = dofile(arg[2])

local function placeholders(s)
    local t = {}
    for p in s:gmatch("%%[%-%d%.]*[sdfxq%%]") do
        if p ~= "%%" then t[#t+1] = p end
    end
    table.sort(t)
    return table.concat(t, ",")
end

local missing, extra, ph_mismatch, count = {}, {}, {}, 0
for k in pairs(canon) do
    if tbl[k] == nil then
        missing[#missing+1] = k
    else
        count = count + 1
        if placeholders(k) ~= placeholders(tbl[k]) then
            ph_mismatch[#ph_mismatch+1] = k
        end
    end
end
for k in pairs(tbl) do
    if canon[k] == nil then extra[#extra+1] = k end
end

print(("%s: translated %d, missing %d, extra %d, placeholder-mismatch %d")
    :format(arg[2]:match("([^/\\]+)$"), count, #missing, #extra, #ph_mismatch))
local function dump(label, list)
    if #list > 0 then
        print("  " .. label .. ":")
        for _, k in ipairs(list) do
            print("    " .. (k:gsub("\n", "\\n")))
        end
    end
end
dump("MISSING", missing)
dump("EXTRA (key not in source)", extra)
dump("PLACEHOLDER MISMATCH", ph_mismatch)
