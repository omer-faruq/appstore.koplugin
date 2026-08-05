-- appstore_manage_ui.lua
-- Installed plugins & patches list UI, update management dialogs, settings, and file management popups

local Device = require("device")
local UIManager = require("ui/uimanager")
local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local SpinWidget = require("ui/widget/spinwidget")
local CheckButton = require("ui/widget/checkbutton")
local PluginPaths = require("appstore_plugin_paths")
local GitHub = require("appstore_net_github")
local Version = require("appstore_version")
local BrowserUI = require("appstore_browser_ui")
local _ = require("appstore_gettext")

local AppStoreManageUI = {}

function AppStoreManageUI.showManagePluginPathsDialog(appstore, settings)
    local hidden_paths = settings:readSetting(PluginPaths.HIDDEN_PLUGIN_PATHS_KEY) or {}
    local lookup_paths = PluginPaths.getLookupPaths()

    local button_dialog
    local buttons = {}
    for _, path in ipairs(lookup_paths) do
        local this_path = path
        local is_hidden = PluginPaths.isPathHidden(this_path, hidden_paths)
        local checkbox_text = is_hidden and "☐ " or "☑ "
        table.insert(buttons, {
            {
                text = checkbox_text .. this_path,
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    local current_hidden = settings:readSetting(PluginPaths.HIDDEN_PLUGIN_PATHS_KEY) or {}
                    local new_hidden = {}
                    local was_hidden = false
                    for _, h in ipairs(current_hidden) do
                        if PluginPaths.isPathHidden(this_path, { h }) then
                            was_hidden = true
                        else
                            table.insert(new_hidden, h)
                        end
                    end
                    if not was_hidden then
                        table.insert(new_hidden, this_path)
                    end
                    settings:saveSetting(PluginPaths.HIDDEN_PLUGIN_PATHS_KEY, new_hidden)
                    settings:flush()
                    UIManager:close(button_dialog)
                    UIManager:nextTick(function()
                        AppStoreManageUI.showManagePluginPathsDialog(appstore, settings)
                    end)
                end,
            },
        })
    end

    table.insert(buttons, {
        {
            text = _("Close"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(button_dialog)
                if appstore and appstore.closeUpdatesDialog then
                    appstore:closeUpdatesDialog(true)
                    appstore:showUpdatesDialog()
                end
            end,
        },
    })

    button_dialog = ButtonDialog:new{
        title = _("Manage plugin paths\n\nHiding a path only affects what AppStore shows/manages here. KOReader will still load plugins from it."),
        title_align = "center",
        buttons = buttons,
        tap_close_callback = function()
            if appstore and appstore.closeUpdatesDialog then
                appstore:closeUpdatesDialog(true)
                appstore:showUpdatesDialog()
            end
        end,
    }
    UIManager:show(button_dialog)
end

function AppStoreManageUI.showCommitCompare(owner, repo_desc, base_tag, head_tag)
    GitHub.runWhenOnline(function()
        local progress = InfoMessage:new{ text = _("Fetching commits…"), timeout = 0 }
        UIManager:show(progress)
        UIManager:forceRePaint()

        local result, err = GitHub.fetchCompareCommits(owner, repo_desc.name, base_tag, head_tag)
        UIManager:close(progress)

        if not result then
            local msg = (type(err) == "table" and err.code == 404)
                and string.format(_("Tag not found on GitHub (%s or %s)."), base_tag, head_tag)
                or  _("Could not fetch commit comparison.")
            UIManager:show(InfoMessage:new{ text = msg, timeout = 5 })
            return
        end

        local commits = result.commits or {}
        local total_commits = result.total_commits or #commits
        if #commits == 0 then
            UIManager:show(InfoMessage:new{ text = _("No commits found between these releases."), timeout = 4 })
            return
        end

        local lines = {
            string.format(_("Commits between %s and %s (%d total):"), base_tag, head_tag, total_commits),
            "",
        }
        for _, c in ipairs(commits) do
            local sha = c.sha and c.sha:sub(1, 7) or ""
            local msg = c.commit and c.commit.message or ""
            local first_line = msg:match("^[^\r\n]+") or msg
            local author = c.commit and c.commit.author and c.commit.author.name or ""
            if author ~= "" then
                table.insert(lines, string.format("• %s (%s, %s)", first_line, sha, author))
            else
                table.insert(lines, string.format("• %s (%s)", first_line, sha))
            end
        end

        local body = table.concat(lines, "\n")
        body = BrowserUI.softWrapLongTokens(body, 60)
        local dialog = ConfirmBox:new{
            text = string.format("%s/%s", owner, repo_desc.name),
            cancel_text = _("Close"),
            no_ok_button = true,
        }
        dialog:addWidget(BrowserUI.makeScrollableTextBoxForDialog(dialog, body))
        UIManager:show(dialog)
    end)
end

return AppStoreManageUI
