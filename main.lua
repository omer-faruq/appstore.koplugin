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
local SpinWidget = require("ui/widget/spinwidget")
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

local ALLOW_DELETE_UNLINKED_PLUGINS_KEY = "allow_delete_unlinked_plugins"
local ALLOW_DELETE_UNLINKED_PATCHES_KEY = "allow_delete_unlinked_patches"
local BROWSER_PAGE_SIZE_KEY = "browser_page_size"
local MANAGE_PAGE_SIZE_KEY = "manage_page_size"
local DEFAULT_BROWSER_PAGE_SIZE = 14
local DEFAULT_MANAGE_PAGE_SIZE = 7
local MIN_BROWSER_PAGE_SIZE = 4
local MAX_BROWSER_PAGE_SIZE = 100
local PLUGIN_TOPICS = { "koreader-plugin" }
local PATCH_TOPICS = { "koreader-user-patch" }
local PLUGIN_NAME_QUERIES = { 'in:name ".koplugin"' }
local PATCH_NAME_QUERIES = { 'in:name "KOReader.patches"' }

local AppStore = WidgetContainer:extend{
    name = "appstore",
    is_doc_only = false,
    is_refreshing = false,
    browser_state = nil,
    browser_menu = nil,
    patch_cache = {},
    updates_state = nil,
    updates_menu = nil,
    patch_updates_state = nil,
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

function AppStore:showBrowser(kind)
    kind = kind or "plugin"
    GitHub.runWhenOnline(function()
        local spinner = Installer.showSpinner(_("Loading repositories…"))
        UIManager:nextTick(function()
            local repos = Cache.listRepos(kind)
            Installer.closeSpinner(spinner)
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
        end)
    end)
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
            local extract_spinner = Installer.showSpinner(_("Installing plugin…"))
            UIManager:nextTick(function()
                local ok_extract, target_dir = Installer.extractPluginToUserDir(reader, { plugin_dirname = repo.name .. ".koplugin", plugin_root = "" })
                reader:close()
                util.removeFile(zip_path)
                Installer.closeSpinner(extract_spinner)
                if not ok_extract then
                    UIManager:show(InfoMessage:new{ text = _("Installation failed: ") .. tostring(target_dir), timeout = 5 })
                    return
                end
                showRestartConfirmation(string.format(_("Installed plugin '%s'."), repo.name))
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
