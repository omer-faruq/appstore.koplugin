-- Extract msgids passed to _() from the appstore plugin source files.
-- Usage: luajit extract.lua <file1> <file2> ...
local seen = {}
local order = {}

local function add(s)
    if s == nil or s == "" then return end
    if not seen[s] then
        seen[s] = true
        order[#order + 1] = s
    end
end

-- Parse a Lua string literal starting at position i (points at the opening
-- quote or '['). Returns the *raw source* text (unescaped) and the position
-- just past the literal, or nil if it isn't a string literal.
local function readString(src, i)
    local c = src:sub(i, i)
    if c == '"' or c == "'" then
        local j = i + 1
        local buf = {}
        while j <= #src do
            local ch = src:sub(j, j)
            if ch == "\\" then
                buf[#buf + 1] = src:sub(j, j + 1)
                j = j + 2
            elseif ch == c then
                return table.concat(buf), j + 1
            else
                buf[#buf + 1] = ch
                j = j + 1
            end
        end
        return nil
    elseif c == "[" then
        local eq = src:match("^%[(=*)%[", i)
        if not eq then return nil end
        local open = "[" .. eq .. "["
        local close = "]" .. eq .. "]"
        local start = i + #open
        local e = src:find(close, start, true)
        if not e then return nil end
        return src:sub(start, e - 1), e + #close
    end
    return nil
end

for _, path in ipairs(arg) do
    local f = assert(io.open(path, "r"))
    local src = f:read("*a")
    f:close()
    local i = 1
    while true do
        -- find next _( not preceded by an identifier char (so we skip foo_( )
        local s = src:find("_%(", i)
        if not s then break end
        local prev = src:sub(s - 1, s - 1)
        if prev:match("[%w_]") then
            i = s + 1
        else
            -- skip whitespace after '('
            local j = s + 2
            while src:sub(j, j):match("%s") do j = j + 1 end
            local str, nextpos = readString(src, j)
            if str then
                -- Convert escaped source to actual value for the common escapes
                str = str:gsub("\\x(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
                str = str:gsub("\\(%d%d?%d?)", function(d) return string.char(tonumber(d)) end)
                str = str:gsub("\\n", "\n"):gsub('\\"', '"'):gsub("\\'", "'"):gsub("\\\\", "\\")
                add(str)
                i = nextpos
            else
                i = s + 2
            end
        end
    end
end

-- Emit a Lua table skeleton
io.write("-- " .. #order .. " unique strings\n")
io.write("return {\n")
for _, s in ipairs(order) do
    local key = ("%q"):format(s)
    io.write("    [" .. key .. "] = " .. key .. ",\n")
end
io.write("}\n")
