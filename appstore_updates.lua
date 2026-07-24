local Device = require("device")
local UIManager = require("ui/uimanager")
local Font = require("ui/font")
local InputContainer = require("ui/widget/container/inputcontainer")
local FocusManager = require("ui/widget/focusmanager")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local Input = Device.input
local FrameContainer = require("ui/widget/container/framecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local TitleBar = require("ui/widget/titlebar")
local Button = require("ui/widget/button")
local TextWidget = require("ui/widget/textwidget")
local GestureRange = require("ui/gesturerange")
local Size = require("ui/size")
local Geom = require("ui/geometry")
local Blitbuffer = require("ffi/blitbuffer")
local _ = require("appstore_gettext")

local UpdatesListItem = InputContainer:extend{
    entry = nil,
    width = nil,
    dialog = nil,
}

local function getListFace()
    local face
    if TextWidget.getDefaultFace then
        face = TextWidget:getDefaultFace()
    end
    if (not face) and Font and Font.getFace then
        face = Font:getFace("smallinfofont")
            or Font:getFace("infofont")
            or Font:getFace("x_smalltfont")
            or Font:getFace("ffont")
            or Font:getFace("infont")
    end
    return face
end

function UpdatesListItem:init()
    local entry = self.entry or {}
    self.entry = entry
    local content_width = self.width or math.floor(math.min(Device.screen:getWidth(), Device.screen:getHeight()) * 0.9)
    local text_args = {
        text = entry.text or "",
        alignment = "left",
        width = content_width - 2 * Size.padding.default,
    }
    local face = getListFace()
    if face then
        text_args.face = face
    end
    local text_widget = TextWidget:new(text_args)
    local background = entry.dim and Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_WHITE
    self.frame = FrameContainer:new{
        padding = Size.padding.default,
        bordersize = 0,
        background = background,
        text_widget,
    }
    self[1] = self.frame
    self.dimen = self.frame:getSize()

    if entry.callback then
        local tap_range = function()
            return Geom:new{ x = self.dimen.x, y = self.dimen.y, w = self.dimen.w, h = self.dimen.h }
        end
        self.ges_events = {
            UpdatesTap = {
                GestureRange:new{ ges = "tap", range = tap_range },
            },
        }
    end
end

function UpdatesListItem:onUpdatesTap()
    if self.entry and self.entry.callback then
        self.entry.callback()
    end
    return true
end

-- Visual focus feedback for non-touch / D-pad devices.
function UpdatesListItem:isFocusable()
    return self.entry and self.entry.callback ~= nil
end

function UpdatesListItem:onFocus()
    if not self.frame then
        return true
    end
    self.frame.invert = true
    UIManager:setDirty(self.show_parent or self, "fast")
    return true
end

function UpdatesListItem:onUnfocus()
    if not self.frame then
        return true
    end
    self.frame.invert = false
    UIManager:setDirty(self.show_parent or self, "fast")
    return true
end

-- Safety-net handler for the synthetic Tap dispatched by FocusManager:onPress.
function UpdatesListItem:onTapSelect()
    if self.entry and self.entry.callback then
        self.entry.callback()
    end
    return true
end

local AppStoreUpdatesDialog = FocusManager:extend{
    appstore = nil,
    title = "",
    items = nil,
    summary_text = nil,
    filter_label = nil,
    on_check_updates = nil,
    on_toggle_filter = nil,
    on_match = nil,
    on_switch_target = nil,
    on_close = nil,
}

function AppStoreUpdatesDialog:init()
    self.show_parent = self
    self.screen_w = Device.screen:getWidth()
    self.screen_h = Device.screen:getHeight()
    self.width = self.screen_w
    self.height = self.screen_h
    self.dimen = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }

    -- Key bindings for non-touch / D-pad devices.
    -- FocusManager already wires Up/Down/Left/Right/Press/Hold from KEY_EVENTS;
    -- we only need a Close shortcut here (no pagination on this dialog).
    if Device:hasKeys() then
        self.key_events.Close = { { Input.group.Back } }
        if Device:hasFewKeys() then
            self.key_events.Close = { { "Left" } }
        end
    end

    self.title_bar = TitleBar:new{
        width = self.width,
        title = self.title or _("AppStore · Updates"),
        fullscreen = false,
        with_bottom_line = true,
        close_callback = function()
            UIManager:close(self)
        end,
        show_parent = self,
    }

    self.check_button = Button:new{
        text = _("Check all updates"),
        menu_style = true,
        callback = function()
            if self.on_check_updates then
                self.on_check_updates()
            end
        end,
    }

    self.filter_button = Button:new{
        text = self.filter_label or _("Show needs update"),
        menu_style = true,
        callback = function()
            if self.on_toggle_filter then
                self.on_toggle_filter()
            end
        end,
    }

    self.match_button = Button:new{
        text = _("Match with repo"),
        menu_style = true,
        callback = function()
            if self.on_match then
                self.on_match()
            end
        end,
    }

    self.switch_button = Button:new{
        text = _("Switch to patches"),
        menu_style = true,
        callback = function()
            if self.on_switch_target then
                self.on_switch_target()
            end
        end,
    }

    self.controls = HorizontalGroup:new{
        self.check_button,
        self.filter_button,
        self.match_button,
        self.switch_button,
    }

    local summary_args = {
        text = self.summary_text or _("No plugins tracked yet."),
        alignment = "left",
    }
    local summary_face = getListFace()
    if summary_face then
        summary_args.face = summary_face
    end
    self.summary_widget = TextWidget:new(summary_args)

    self.list_group = VerticalGroup:new{}
    self.list_container = FrameContainer:new{
        padding = Size.padding.default,
        bordersize = 0,
        self.list_group,
    }

    local list_height = self.screen_h - self.title_bar:getHeight() - self.controls:getSize().h - 3 * Size.span.vertical_default

    self.scroller = ScrollableContainer:new{
        dimen = Geom:new{ w = self.width, h = list_height },
        show_parent = self,
        self.list_container,
    }
    self.cropping_widget = self.scroller

    self.content = VerticalGroup:new{
        self.title_bar,
        self.controls,
        FrameContainer:new{ padding = Size.padding.default, self.summary_widget },
        self.scroller,
    }

    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        self.content,
    }

    self:setItems(self.items or {})

    if Device:hasDPad() and self.layout and #self.layout > 0 then
        UIManager:nextTick(function()
            -- Land focus on the first focusable widget visible to D-pad users.
            self:moveFocusTo(self.selected.x, self.selected.y, FocusManager.FOCUS_ONLY_ON_NT)
            self:_ensureFocusedVisible()
        end)
    end
end

function AppStoreUpdatesDialog:setItems(items)
    self.items = items or {}
    self.list_group:clear()
    self._focusable_items = {}
    self._focusable_row_offsets = {}
    for idx, entry in ipairs(self.items) do
        local item = UpdatesListItem:new{
            entry = entry,
            width = self.width - 2 * Size.padding.default,
            dialog = self,
            show_parent = self,
        }
        self.list_group[#self.list_group + 1] = item
        if item:isFocusable() then
            self._focusable_items[#self._focusable_items + 1] = item
        end
        if idx < #self.items then
            self.list_group[#self.list_group + 1] = VerticalSpan:new{ width = Size.span.vertical_default }
        end
    end
    self:_rebuildLayout()
    UIManager:setDirty(self)
end

-- Build / rebuild the FocusManager 2-D layout. Rows:
--   1) optional title bar buttons (close X)
--   2) top control row { Check, Filter, Match, Switch }
--   3) one row per focusable list item
function AppStoreUpdatesDialog:_rebuildLayout()
    self.layout = {}

    if self.title_bar and self.title_bar.generateHorizontalLayout then
        local title_rows = self.title_bar:generateHorizontalLayout()
        for _, row in ipairs(title_rows) do
            table.insert(self.layout, row)
        end
    end

    local controls_row = {}
    for _, btn in ipairs({ self.check_button, self.filter_button, self.match_button, self.switch_button }) do
        if btn then
            table.insert(controls_row, btn)
        end
    end
    if #controls_row > 0 then
        table.insert(self.layout, controls_row)
    end

    local first_list_row_index = #self.layout + 1
    for _, item in ipairs(self._focusable_items or {}) do
        table.insert(self.layout, { item })
    end

    -- Recompute cumulative Y offsets for each focusable row inside list_group
    -- so :_ensureFocusedVisible() can scroll the focused item into view.
    do
        local cursor_y = Size.padding.default
        for _, child in ipairs(self.list_group) do
            local size = child.getSize and child:getSize() or { h = 0 }
            local h = size.h or 0
            if child.isFocusable and child:isFocusable() then
                self._focusable_row_offsets[child] = { y = cursor_y, h = h }
            end
            cursor_y = cursor_y + h
        end
    end

    -- Initial / current focus selection. If we still have a previous focus
    -- inside the list area, try to keep it; otherwise land on the controls row
    -- (or first focusable list item if controls are absent).
    if not self.selected then
        self.selected = { x = 1, y = 1 }
    end
    if not (self.layout[self.selected.y] and self.layout[self.selected.y][self.selected.x]) then
        if #self._focusable_items > 0 then
            self.selected = { x = 1, y = first_list_row_index }
        elseif #self.layout > 0 then
            self.selected = { x = 1, y = 1 }
        end
    end
end

function AppStoreUpdatesDialog:setSummary(text)
    if self.summary_widget then
        self.summary_widget:setText(text or "")
        UIManager:setDirty(self)
    end
end

function AppStoreUpdatesDialog:setFilterLabel(text)
    if self.filter_button and text then
        self.filter_button:setText(text)
        UIManager:setDirty(self)
    end
end

function AppStoreUpdatesDialog:onCloseWidget()
    if self.on_close then
        self.on_close()
    end
end

function AppStoreUpdatesDialog:onClose()
    UIManager:close(self)
    return true
end

-- After the FocusManager moves focus, scroll the inner ScrollableContainer so
-- that the newly focused list row is visible. Title-bar / controls rows live
-- outside the scrollable area and are skipped.
function AppStoreUpdatesDialog:_ensureFocusedVisible()
    local focused = self:getFocusItem()
    if not focused or not self.scroller then
        return
    end
    local offset = self._focusable_row_offsets and self._focusable_row_offsets[focused]
    if not offset then
        return
    end
    local scroller = self.scroller
    if not scroller._is_scrollable then
        return
    end
    local scroll_y = scroller._scroll_offset_y or 0
    local crop_h = scroller._crop_h or (scroller.dimen and scroller.dimen.h) or 0
    if crop_h <= 0 then
        return
    end
    local target_top = offset.y
    local target_bottom = offset.y + offset.h
    if target_top < scroll_y then
        scroller:_scrollBy(0, target_top - scroll_y)
    elseif target_bottom > scroll_y + crop_h then
        scroller:_scrollBy(0, target_bottom - (scroll_y + crop_h))
    end
end

function AppStoreUpdatesDialog:onFocusMove(args)
    local handled = FocusManager.onFocusMove(self, args)
    self:_ensureFocusedVisible()
    return handled
end

return AppStoreUpdatesDialog

