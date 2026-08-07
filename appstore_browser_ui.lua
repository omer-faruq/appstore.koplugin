-- appstore_browser_ui.lua
-- Catalog browser UI, search dialogs, filter/sort popups, item details, and README viewer

local Device = require("device")
local UIManager = require("ui/uimanager")
local InputContainer = require("ui/widget/container/inputcontainer")
local FocusManager = require("ui/widget/focusmanager")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local Geom = require("ui/geometry")
local TitleBar = require("ui/widget/titlebar")
local Button = require("ui/widget/button")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local VerticalSpan = require("ui/widget/verticalspan")
local LineWidget = require("ui/widget/linewidget")
local Size = require("ui/size")
local Blitbuffer = require("ffi/blitbuffer")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local TextViewer = require("ui/widget/textviewer")
local TextWidget = require("ui/widget/textwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local Font = require("ui/font")
local VerticalGroup = require("ui/widget/verticalgroup")
local FrameContainer = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local GestureRange = require("ui/gesturerange")

local _ = require("appstore_gettext")
local Input = Device.input

local AppStoreBrowserUI = {}

function AppStoreBrowserUI.softWrapLongTokens(text, max_len)
    max_len = tonumber(max_len) or 60
    if not text or text == "" then
        return ""
    end
    text = tostring(text)
    return text:gsub("(%S+)", function(token)
        if #token <= max_len then
            return token
        end
        if token:match("[\128-\255]") then
            return token
        end
        local parts = {}
        local i = 1
        while i <= #token do
            parts[#parts + 1] = token:sub(i, i + max_len - 1)
            i = i + max_len
        end
        return table.concat(parts, "\n")
    end)
end

function AppStoreBrowserUI.makeTextBox(text)
    local args = {
        text = text,
        width = math.floor(Device.screen:getWidth() * 0.8),
    }
    local face
    if TextWidget.getDefaultFace then
        face = TextWidget:getDefaultFace()
    end
    if not face and Font and Font.getFace then
        face = Font:getFace("infofont")
    end
    if face then
        args.face = face
    end
    return TextBoxWidget:new(args)
end

function AppStoreBrowserUI.makeScrollableTextBox(text)
    local width = math.floor(Device.screen:getWidth() * 0.9)
    local height = math.floor(Device.screen:getHeight() * 0.7)
    local default_face = nil
    if TextWidget.getDefaultFace then
        default_face = TextWidget:getDefaultFace()
    end
    if (not default_face) and Font and Font.getFace then
        default_face = Font:getFace("infofont")
    end
    local box = TextBoxWidget:new{
        text = text,
        width = width - 2 * Size.padding.default,
        face = default_face,
    }
    local frame = FrameContainer:new{
        padding = Size.padding.default,
        bordersize = 0,
        box,
    }
    return ScrollableContainer:new{
        dimen = Geom:new{ w = width, h = height },
        frame,
    }
end

function AppStoreBrowserUI.makeScrollableTextBoxForDialog(dialog, text)
    local width = dialog and dialog.getAddedWidgetAvailableWidth and dialog:getAddedWidgetAvailableWidth()
    width = tonumber(width) or math.floor(Device.screen:getWidth() * 0.8)
    local height = math.floor(Device.screen:getHeight() * 0.7)
    local scrollbar_slack = 3 * Device.screen:scaleBySize(6)
    local content_width = math.max(width - scrollbar_slack, 200)
    local default_face = nil
    if TextWidget.getDefaultFace then
        default_face = TextWidget:getDefaultFace()
    end
    if (not default_face) and Font and Font.getFace then
        default_face = Font:getFace("infofont")
    end

    local box = TextBoxWidget:new{
        text = text,
        width = math.max(content_width - 2 * Size.padding.default, 160),
        face = default_face,
    }
    local frame = FrameContainer:new{
        padding = Size.padding.default,
        bordersize = 0,
        box,
    }
    return ScrollableContainer:new{
        dimen = Geom:new{ w = width, h = height },
        show_parent = dialog,
        frame,
    }
end

local AppStoreListItem = InputContainer:extend{
    entry = nil,
    width = nil,
    dialog = nil,
}

function AppStoreListItem:init()
    local entry = self.entry or {}
    local text = entry.text or ""
    local text_w = self.width - 2 * Size.padding.default
    local face
    if TextWidget.getDefaultFace then
        face = TextWidget:getDefaultFace()
    end
    if not face and Font and Font.getFace then
        face = Font:getFace("infofont")
    end
    local text_args = {
        text = text,
        width = text_w,
    }
    if face then text_args.face = face end
    local text_widget = TextBoxWidget:new(text_args)

    local bg_color = Blitbuffer.COLOR_WHITE
    if entry.dim then bg_color = Blitbuffer.COLOR_LIGHT_GRAY end

    local frame = FrameContainer:new{
        padding = Size.padding.default,
        bordersize = Size.border.thin,
        background = bg_color,
        text_widget,
    }
    self[1] = frame
    self.dimen = frame:getSize()

    if entry.is_entry or entry.callback then
        self.ges_events = {
            AppStoreTap = {
                GestureRange:new{
                    ges = "tap",
                    range = self.dimen,
                },
            },
            AppStoreHold = {
                GestureRange:new{
                    ges = "hold",
                    range = self.dimen,
                },
            },
        }
    end
end

function AppStoreListItem:onAppStoreTap()
    self:onTapSelect()
    return true
end

function AppStoreListItem:onAppStoreHold()
    self:onHoldSelect()
    return true
end

function AppStoreListItem:isFocusable()
    local entry = self.entry or {}
    return entry.is_entry or entry.callback ~= nil
end

function AppStoreListItem:onFocus()
    if self[1] then
        self[1].background = Blitbuffer.COLOR_LIGHT_GRAY
        UIManager:setDirty(self, "partial")
    end
    return true
end

function AppStoreListItem:onUnfocus()
    if self[1] then
        local entry = self.entry or {}
        self[1].background = entry.dim and Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_WHITE
        UIManager:setDirty(self, "partial")
    end
    return true
end

function AppStoreListItem:onTapSelect()
    local entry = self.entry or {}
    if entry.callback then
        entry.callback()
    end
end

function AppStoreListItem:onHoldSelect()
    local entry = self.entry or {}
    if entry.hold_callback then
        entry.hold_callback()
    elseif entry.callback then
        entry.callback()
    end
end

AppStoreBrowserUI.AppStoreListItem = AppStoreListItem

local AppStoreBrowserDialog = FocusManager:extend{
    AppStore = nil,
    title = "",
    items = nil,
    width = nil,
    page = 1,
    total_pages = 1,
    scroll_offset = nil,
    on_prev_page = nil,
    on_next_page = nil,
    on_dismiss = nil,
    on_settings_tap = nil,
}

function AppStoreBrowserDialog:init()
    self.show_parent = self
    self.screen_w = Device.screen:getWidth()
    self.screen_h = Device.screen:getHeight()
    self.width = self.screen_w
    self.height = self.screen_h
    self.dimen = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }

    if Device:hasKeys() then
        self.key_events.Close = { { Input.group.Back } }
        if Device:hasFewKeys() then
            self.key_events.Close = { { "Left" } }
        end
        self.key_events.NextPage = { { Input.group.PgFwd } }
        self.key_events.PrevPage = { { Input.group.PgBack } }
        self.key_events.ShowMenu = { { "Menu" } }
    end
    if Device:hasKeyboard() then
        self.key_events.HotkeyRefresh = { { "R" } }
        self.key_events.HotkeyFilter = { { "F" } }
        self.key_events.HotkeySort = { { "S" } }
        self.key_events.HotkeySwitchTab = { { "T" } }
    end

    self.title_bar = TitleBar:new{
        width = self.width,
        title = self.title,
        fullscreen = false,
        with_bottom_line = true,
        left_icon = "appbar.settings",
        left_icon_tap_callback = function()
            if self.on_settings_tap then
                self.on_settings_tap()
            end
        end,
        close_callback = function()
            UIManager:close(self)
        end,
        show_parent = self,
    }

    self._focusable_items = {}
    self._focusable_row_offsets = {}

    local list_group = VerticalGroup:new{}
    local entry_width = self:getListEntryWidth()
    local Trapper = require("ui/trapper")
    local total_items = self.items and #self.items or 0
    local show_progress = total_items > 30 and Trapper:isWrapped()

    local cumulative_y = 0
    local first_list_row_index = nil

    if self.items and #self.items > 0 then
        for idx, entry in ipairs(self.items) do
            if show_progress and (idx % 10 == 0 or idx == total_items) then
                Trapper:info(string.format(_("Rendering page… (%d/%d)"), idx, total_items))
            end

            local row_item
            if type(entry) == "table" and entry.is_widget then
                row_item = entry
            else
                row_item = AppStoreListItem:new{
                    entry = entry,
                    width = entry_width,
                    dialog = self,
                }
            end

            table.insert(list_group, row_item)

            if row_item.isFocusable and row_item:isFocusable() then
                table.insert(self._focusable_items, row_item)
                table.insert(self._focusable_row_offsets, cumulative_y)
                if not first_list_row_index then
                    first_list_row_index = #self._focusable_items
                end
            end

            local h = (row_item.getSize and row_item:getSize().h)
                   or (row_item.dimen and row_item.dimen.h)
                   or 0
            cumulative_y = cumulative_y + h
        end
    else
        table.insert(list_group, AppStoreListItem:new{
            entry = { text = _("No repositories found."), select_enabled = false },
            width = entry_width,
            dialog = self,
        })
    end

    local title_h = self.title_bar:getSize().h
    local footer_reserved_h = math.floor(self.screen_h * 0.12)
    local list_max_h = self.screen_h - title_h - footer_reserved_h

    self.list_scroller = ScrollableContainer:new{
        dimen = Geom:new{ x = 0, y = title_h, w = self.width, h = list_max_h },
        show_parent = self,
        list_group,
    }

    if self.scroll_offset then
        self.list_scroller:setScrolledOffset(self.scroll_offset)
    end

    local actual_list_h = self.list_scroller:getSize().h
    local footer_y = title_h + actual_list_h
    local remaining_h = math.max(self.screen_h - footer_y, 40)

    self.btn_prev = Button:new{
        text = _("Previous"),
        enabled = self.page > 1,
        callback = function()
            if self.on_prev_page then self.on_prev_page() end
        end,
    }

    self.btn_next = Button:new{
        text = _("Next"),
        enabled = self.page < self.total_pages,
        callback = function()
            if self.on_next_page then self.on_next_page() end
        end,
    }

    self.btn_menu = Button:new{
        text = _("Menu"),
        callback = function()
            self:onShowMenu()
        end,
    }

    local page_label = TextWidget:new{
        text = string.format("%d / %d", self.page, math.max(self.total_pages, 1)),
        face = Font:getFace("infofont"),
    }

    local footer_layout = HorizontalGroup:new{
        align = "center",
        self.btn_prev,
        HorizontalSpan:new{ width = Size.padding.default },
        self.btn_next,
        HorizontalSpan:new{ width = Size.padding.default },
        page_label,
        HorizontalSpan:new{ width = Size.padding.default },
        self.btn_menu,
    }

    self.footer_container = FrameContainer:new{
        dimen = Geom:new{ x = 0, y = footer_y, w = self.width, h = remaining_h },
        padding = Size.padding.small,
        bordersize = 0,
        CenterContainer:new{
            dimen = Geom:new{ x = 0, y = footer_y, w = self.width, h = remaining_h },
            footer_layout,
        },
    }

    self.footer_buttons = {
        prev = self.btn_prev,
        next = self.btn_next,
        menu = self.btn_menu,
    }

    table.insert(self._focusable_items, self.btn_prev)
    table.insert(self._focusable_items, self.btn_next)
    table.insert(self._focusable_items, self.btn_menu)

    self[1] = VerticalGroup:new{
        align = "left",
        self.title_bar,
        self.list_scroller,
        self.footer_container,
    }

    if Device:hasKeys() then
        local initial_focus_index = self:_resolveInitialFocus(first_list_row_index)
        if initial_focus_index then
            self:switchFocusTo(initial_focus_index)
        end
    end
end

function AppStoreBrowserDialog:getListEntryWidth()
    local scrollbar_slack = 3 * Device.screen:scaleBySize(6)
    return math.max(self.width - scrollbar_slack, 200)
end

function AppStoreBrowserDialog:onCloseWidget()
    if self.on_dismiss then
        self.on_dismiss()
    end
end

function AppStoreBrowserDialog:onClose()
    UIManager:close(self)
end

function AppStoreBrowserDialog:_resolveInitialFocus(first_list_row_index)
    if first_list_row_index then
        return first_list_row_index
    end
    if self.btn_next and self.btn_next.enabled then return #self._focusable_items - 1 end
    if self.btn_prev and self.btn_prev.enabled then return #self._focusable_items - 2 end
    if self.btn_menu then return #self._focusable_items end
    return 1
end

function AppStoreBrowserDialog:onNextPage()
    if self.on_next_page and self.page < self.total_pages then
        self.on_next_page()
    end
end

function AppStoreBrowserDialog:onPrevPage()
    if self.on_prev_page and self.page > 1 then
        self.on_prev_page()
    end
end

function AppStoreBrowserDialog:onShowMenu()
    if self.AppStore and self.AppStore.showBrowserActionMenu then
        self.AppStore:showBrowserActionMenu(self)
    end
end

function AppStoreBrowserDialog:getScrollOffset()
    if self.list_scroller then
        return self.list_scroller:getScrolledOffset()
    end
    return { x = 0, y = 0 }
end

function AppStoreBrowserDialog:setScrollOffset(offset)
    if self.list_scroller and offset then
        self.list_scroller:setScrolledOffset(offset)
    end
end

AppStoreBrowserUI.AppStoreBrowserDialog = AppStoreBrowserDialog

return AppStoreBrowserUI
