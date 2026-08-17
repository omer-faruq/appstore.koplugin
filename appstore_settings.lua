local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

local settings_path = DataStorage:getSettingsDir() .. "/appstore.lua"

return LuaSettings:open(settings_path)
