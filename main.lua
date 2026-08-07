-- main.lua
-- AppStore plugin entry point and main orchestrator module

local Device = require("device")
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local ButtonDialog = require("ui/widget/buttondialog")
local Dispatcher = require("dispatcher")
local Blitbuffer = require("ffi/blitbuffer")
local util = require("util")
local Archiver = require("ffi/archiver")
local TextViewer = require("ui/widget/textviewer")

local _ = require("appstore_gettext")
local Cache = require("appstore_cache")
local GitHub = require("appstore_net_github")
local RepoContent = require("appstore_repo_content")
local InstallStore = require("appstore_installs")
local PluginPaths = require("appstore_plugin_paths")
local Version = require("appstore_version")
local Installer = require("appstore_installer")
local BrowserUI = require("appstore_browser_ui")
local ManageUI = require("appstore_manage_ui")

local SETTINGS_PATH = DataStorage:getSettingsDir() .. "/appstore.lua"
local AppStoreSettings = LuaSettings:open(SETTINGS_PATH)

local PLUGIN_TOPICS = { "koreader-plugin" }
local PATCH_TOPICS = { "koreader-user-patch" }
local PLUGIN_NAME_QUERIES = { 'in:name ".koplugin"' }
local PATCH_NAME_QUERIES = { 'in:name "KOReader.patches"' }

local AppStore = WidgetContainer:extend{
    name = "appstore",
    is_doc_only = false,
    is_refreshing = false,
    current_kind = "plugin",
    browser_menu = nil,
    updates_menu = nil,
    patch_updates_menu = nil,
}

function AppStore:init()
    self.cache_dir = DataStorage:getDataDir() .. "/cache/appstore"
    util.makePath(self.cache_dir)
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function AppStore:addToMainMenu(menu_items)
    menu_items.AppStore = {
        sorting_hint = "tools",
        text = _("App Store"),
        callback = function()
            self:showBrowser()
        end,
    }
end

function AppStore:onDispatcherRegisterActions()
    Dispatcher:registerAction("AppStore_open", {
        category = "none",
        event = "OpenAppStoreMenu",
        title = _("Open AppStore"),
        general = true,
    })
end

function AppStore:onOpenAppStoreMenu()
    UIManager:nextTick(function()
        self:showBrowser()
    end)
end

function AppStore:onCloseWidget()
    Cache.close()
end

function AppStore:onSuspend()
    Cache.close()
end

local function showRestartConfirmation(message)
    UIManager:show(ConfirmBox:new{
        text = message .. "\n\n" .. _("This will take effect on next restart."),
        ok_text = _("Restart now"),
        ok_callback = function()
            UIManager:restartKOReader()
        end,
        cancel_text = _("Restart later"),
        background = Blitbuffer.COLOR_WHITE,
    })
end

function AppStore:fetchAndStore(kind, topics, name_queries)
    local collected = {}
    local seen = {}
    local function append(repo)
        if repo and repo.id and not seen[repo.id] then
            seen[repo.id] = true
            table.insert(collected, repo)
        end
    end

    if topics then
        local res, err = GitHub.searchByTopics(topics, { per_page = 100 })
        if res and res.items then
            for _, repo in ipairs(res.items) do
                append(repo)
            end
        end
    end

    if name_queries then
        for _, q in ipairs(name_queries) do
            local res, err = GitHub.searchRepositories({ q = q, per_page = 100 })
            if res and res.items then
                for _, repo in ipairs(res.items) do
                    append(repo)
                end
            end
        end
    end

    Cache.storeRepos(kind, collected)
    return #collected
end

function AppStore:refreshCache(kind)
    if self.is_refreshing then return end
    kind = kind or self.current_kind or "plugin"
    self.is_refreshing = true
    local progress = InfoMessage:new{ text = _("Refreshing catalog…"), timeout = 0 }
    UIManager:show(progress)

    local ok, err = pcall(function()
        if kind == "plugin" or kind == "all" then
            self:fetchAndStore("plugin", PLUGIN_TOPICS, PLUGIN_NAME_QUERIES)
        end
        if kind == "patch" or kind == "all" then
            self:fetchAndStore("patch", PATCH_TOPICS, PATCH_NAME_QUERIES)
        end
    end)

    UIManager:close(progress)
    self.is_refreshing = false

    if ok then
        UIManager:show(InfoMessage:new{ text = _("Catalog updated successfully."), timeout = 3 })
    else
        UIManager:show(InfoMessage:new{ text = _("Catalog update failed: ") .. tostring(err), timeout = 5 })
    end
end

function AppStore:showBrowser(kind)
    kind = kind or "plugin"
    self.current_kind = kind
    local repos = Cache.listRepos(kind)
    if #repos == 0 then
        GitHub.runWhenOnline(function()
            self:refreshCache(kind)
            repos = Cache.listRepos(kind)
            self:renderBrowserDialog(kind, repos)
        end)
        return
    end
    self:renderBrowserDialog(kind, repos)
end

function AppStore:renderBrowserDialog(kind, repos)
    local items = {}
    for _, repo in ipairs(repos) do
        table.insert(items, {
            text = string.format("• %s\n  %s", repo.full_name or repo.name, repo.description or ""),
            is_entry = true,
            callback = function()
                self:promptRepoAction(repo)
            end,
        })
    end
    local dialog = BrowserUI.AppStoreBrowserDialog:new{
        title = kind == "plugin" and _("App Store · Plugins") or _("App Store · Patches"),
        items = items,
        appstore = self,
        on_settings_tap = function()
            self:showAppStoreSettingsDialog()
        end,
    }
    self.browser_menu = dialog
    UIManager:show(dialog)
end

function AppStore:showBrowserActionMenu(dialog)
    local button_dialog
    local buttons = {
        {
            {
                text = _("Refresh catalog"),
                callback = function()
                    if button_dialog then UIManager:close(button_dialog) end
                    if dialog then UIManager:close(dialog) end
                    GitHub.runWhenOnline(function()
                        self:refreshCache(self.current_kind or "plugin")
                        self:showBrowser(self.current_kind or "plugin")
                    end)
                end,
            },
            {
                text = (self.current_kind == "patch") and _("Switch to Plugins") or _("Switch to Patches"),
                callback = function()
                    if button_dialog then UIManager:close(button_dialog) end
                    if dialog then UIManager:close(dialog) end
                    local target_kind = (self.current_kind == "patch") and "plugin" or "patch"
                    self:showBrowser(target_kind)
                end,
            },
        },
        {
            {
                text = _("Installed plugins"),
                callback = function()
                    if button_dialog then UIManager:close(button_dialog) end
                    self:showUpdatesDialog()
                end,
            },
            {
                text = _("Settings"),
                callback = function()
                    if button_dialog then UIManager:close(button_dialog) end
                    self:showAppStoreSettingsDialog()
                end,
            },
        },
        {
            {
                text = _("Close"),
                callback = function()
                    if button_dialog then UIManager:close(button_dialog) end
                end,
            },
        },
    }
    button_dialog = ButtonDialog:new{
        title = _("App Store Menu"),
        buttons = buttons,
    }
    UIManager:show(button_dialog)
end

function AppStore:promptRepoAction(repo)
    if not repo then return end
    local buttons_row = {}
    if (repo.kind or "plugin") == "plugin" then
        table.insert(buttons_row, {
            text = _("Install plugin"),
            callback = function()
                self:installPluginFromRepo(repo)
            end,
        })
    end
    table.insert(buttons_row, {
        text = _("View README"),
        callback = function()
            self:showReadme(repo)
        end,
    })
    local dialog = ConfirmBox:new{
        text = repo.full_name or repo.name or _("Repository"),
        cancel_text = _("Close"),
        no_ok_button = true,
        other_buttons_first = true,
        other_buttons = { buttons_row },
    }
    dialog:addWidget(BrowserUI.makeTextBox(repo.description or ""))
    UIManager:show(dialog)
end

function AppStore:showReadme(repo)
    local owner = repo.owner or (repo.data and repo.data.owner and repo.data.owner.login)
    if not owner or not repo.name then
        UIManager:show(InfoMessage:new{ text = _("Missing repository metadata for README download."), timeout = 4 })
        return
    end
    GitHub.runWhenOnline(function()
        local spinner = Installer.showSpinner(_("Fetching README…"))
        UIManager:nextTick(function()
            local content, err = RepoContent.fetchReadmeContent(owner, repo.name)
            Installer.closeSpinner(spinner)
            if not content then
                UIManager:show(InfoMessage:new{ text = _("README download failed: ") .. tostring(err), timeout = 4 })
                return
            end
            UIManager:show(TextViewer:new{
                title = string.format(_("README: %s/%s"), owner, repo.name),
                text = content,
                add_default_buttons = true,
                text_format = "md",
            })
        end)
    end)
end

function AppStore:installPluginFromRepo(repo)
    if not repo then return end
    GitHub.runWhenOnline(function()
        local owner = repo.owner or (repo.data and repo.data.owner and repo.data.owner.login)
        if not owner or not repo.name then
            UIManager:show(InfoMessage:new{ text = _("Missing repository metadata for installation."), timeout = 4 })
            return
        end
        local url = string.format("https://api.github.com/repos/%s/%s/zipball", owner, repo.name)
        local zip_path = string.format("%s/downloads/%s-%d.zip", self.cache_dir, repo.name, os.time())
        local spinner = Installer.showSpinner(_("Downloading plugin archive…"))
        UIManager:nextTick(function()
            local ok, err = Installer.downloadToFile(url, zip_path)
            Installer.closeSpinner(spinner)
            if not ok then
                util.removeFile(zip_path)
                UIManager:show(InfoMessage:new{ text = _("Download failed: ") .. tostring(err), timeout = 5 })
                return
            end
            local reader = Archiver.Reader:new()
            if not reader:open(zip_path) then
                util.removeFile(zip_path)
                UIManager:show(InfoMessage:new{ text = _("Failed to open downloaded archive."), timeout = 5 })
                return
            end
            local info, err_detect = Installer.detectPluginFromArchive(reader, repo)
            if not info then
                reader:close()
                util.removeFile(zip_path)
                UIManager:show(InfoMessage:new{ text = err_detect or _("Failed to detect plugin structure in archive."), timeout = 5 })
                return
            end
            local extract_spinner = Installer.showSpinner(_("Installing plugin…"))
            UIManager:nextTick(function()
                local ok_extract, target_dir = Installer.extractPluginToUserDir(reader, info)
                reader:close()
                util.removeFile(zip_path)
                Installer.closeSpinner(extract_spinner)
                if not ok_extract then
                    UIManager:show(InfoMessage:new{ text = _("Installation failed: ") .. tostring(target_dir), timeout = 5 })
                    return
                end
                showRestartConfirmation(string.format(_("Installed plugin '%s'."), info.plugin_name or repo.name))
            end)
        end)
    end)
end

function AppStore:showUpdatesDialog()
    local installed = InstallStore.list()
    local items = {}
    for dirname, record in pairs(installed) do
        table.insert(items, {
            text = string.format("• %s (installed)", dirname),
            is_entry = true,
        })
    end
    if #items == 0 then
        table.insert(items, { text = _("No installed plugins to display."), select_enabled = false })
    end
    local dialog = BrowserUI.AppStoreBrowserDialog:new{
        title = _("App Store · Installed plugins"),
        items = items,
        appstore = self,
        on_settings_tap = function()
            ManageUI.showManagePluginPathsDialog(self, AppStoreSettings)
        end,
    }
    self.updates_menu = dialog
    UIManager:show(dialog)
end

function AppStore:showPatchUpdatesDialog()
    local installed = InstallStore.listPatches()
    local items = {}
    for filename, record in pairs(installed) do
        table.insert(items, {
            text = string.format("• %s (installed patch)", filename),
            is_entry = true,
        })
    end
    if #items == 0 then
        table.insert(items, { text = _("No installed patches to display."), select_enabled = false })
    end
    local dialog = BrowserUI.AppStoreBrowserDialog:new{
        title = _("App Store · Installed patches"),
        items = items,
        appstore = self,
    }
    self.patch_updates_menu = dialog
    UIManager:show(dialog)
end

function AppStore:showAppStoreSettingsDialog()
    local button_dialog
    local buttons = {
        {
            {
                text = _("Manage plugin paths"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(button_dialog)
                    ManageUI.showManagePluginPathsDialog(self, AppStoreSettings)
                end,
            },
        },
        {
            {
                text = _("Close"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(button_dialog)
                end,
            },
        },
    }
    button_dialog = ButtonDialog:new{
        title = _("App Store Settings"),
        buttons = buttons,
    }
    UIManager:show(button_dialog)
end

return AppStore

