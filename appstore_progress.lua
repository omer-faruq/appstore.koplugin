--[[--
A progress dialog for the long refreshes: a title bar with a close button, and a bar.

Why not KOReader's own `ProgressbarDialog`: that one dismisses on *any* key and on a tap
anywhere on the screen, which is far too easy to trigger by accident during a refresh that
runs for a minute or more. Here only two things stop it — the Back key and the cross in the
title bar — and the cross is what makes it reachable on touch devices, where there is no
Back key at all.

    local progress = AppStoreProgress:new{ title = _("Refreshing plugins…") }
    progress:show()
    progress:setFraction(0.25)        -- 0..1; redraws at most every `redraw_interval`
    UIManager:close(progress)

`cancel_callback` fires only when the user stops it, not when we close it ourselves.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local CenterContainer = require("ui/widget/container/centercontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local ProgressWidget = require("ui/widget/progresswidget")
local Size = require("ui/size")
local TitleBar = require("ui/widget/titlebar")
local time = require("ui/time")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen

-- Not modal, on purpose. Input does not leak either way -- UIManager:sendEvent hands the event
-- to the topmost non-toast widget, whatever its modal flag -- so the only difference is the
-- stacking order against other modals, and during a refresh that runs for a minute the dialogs
-- liable to appear over it, network or battery, are ones the reader wants on top.
local AppStoreProgress = InputContainer:extend{
    title = nil,
    cancel_callback = nil,
    -- On e-ink a bar that changes several times a second is unpleasant to look at, and
    -- every redraw costs real time on the slow ones.
    redraw_interval = 1.5,
}

function AppStoreProgress:init()
    self.align = "center"
    self.dimen = Screen:getSize()
    self._last_redraw = time.now()
    self._fraction = 0
    self._cancelled = false

    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
        -- Devices with few keys have no Back at all; ui/widget/menu.lua replaces it with
        -- Left there, and this dialog follows the same convention.
        if Device:hasFewKeys() then
            self.key_events.Close = { { "Left" } }
        end
    end
    if Device:isTouchDevice() then
        -- Only over the dialog itself: a tap anywhere else must not cancel a refresh.
        self.ges_events.TapClose = {
            GestureRange:new{
                ges = "tap",
                range = function() return self.frame and self.frame.dimen or Geom:new{} end,
            },
        }
    end

    local width = math.floor(Screen:getWidth() * 0.8)
    self.title_bar = TitleBar:new{
        width = width,
        align = "left",
        title = self.title or "",
        with_bottom_line = true,
        -- Only where it can be pressed. On a keyboard-only device the cross is unreachable
        -- decoration, and Back does the job.
        close_callback = Device:isTouchDevice() and function()
            self:cancel()
        end or nil,
        show_parent = self,
    }
    self.progress_bar = ProgressWidget:new{
        width = width - 2 * Size.padding.large,
        height = Screen:scaleBySize(18),
        percentage = 0,
        fillcolor = Blitbuffer.COLOR_BLACK,
    }

    self.frame = FrameContainer:new{
        radius = Size.radius.window,
        bordersize = Size.border.window,
        padding = Size.padding.large,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            -- The bar is narrower than the title bar; left-aligned it sat visibly off to
            -- one side of the frame.
            align = "center",
            self.title_bar,
            VerticalSpan:new{ width = Size.padding.large },
            self.progress_bar,
        },
    }
    -- Centred explicitly rather than through the container's own `align`: this widget
    -- covers the screen, and without it the dialog sat against the top edge.
    self[1] = CenterContainer:new{
        dimen = Screen:getSize(),
        self.frame,
    }
end

function AppStoreProgress:show()
    UIManager:show(self, "ui")
    -- The refresh that follows runs synchronously, so nothing would draw the dialog
    -- before it starts unless we ask for it here.
    UIManager:forceRePaint()
end

--- Report progress. `fraction` is 0..1; values outside are clamped.
function AppStoreProgress:setFraction(fraction)
    fraction = tonumber(fraction) or 0
    if fraction < 0 then fraction = 0 end
    if fraction > 1 then fraction = 1 end
    self._fraction = fraction
    self.progress_bar:setPercentage(fraction)

    -- os.time() only counts whole seconds, which cannot express the interval below.
    local now = time.now()
    if time.to_s(now - self._last_redraw) < self.redraw_interval then
        return false
    end
    self._last_redraw = now
    -- The bar alone, in the fast waveform: the rest of the dialog never changes.
    UIManager:setDirty(self, "fast", self.progress_bar.dimen)
    UIManager:forceRePaint()
    self:pump()
    return true
end

--- Hand control back to UIManager for a moment, so it can read the input queue.
-- The work around this widget is synchronous, and a key press sitting in that queue is
-- not seen until someone reads it: without this, Back does nothing until the whole
-- refresh is over. Requires a coroutine around the caller (Trapper:wrap).
function AppStoreProgress:pump()
    local co = coroutine.running()
    if not co then
        return
    end
    -- Half of what ui/trapper waits, and for the same reason: at 0.01 the scheduled resume
    -- beats the input handler and the press is missed.
    local resume = function() coroutine.resume(co, true) end
    UIManager:scheduleIn(0.05, resume)
    coroutine.yield()
    UIManager:unschedule(resume)
end

--- Change the heading mid-run, to name the stage the work has moved on to.
function AppStoreProgress:setTitle(title)
    self.title = title
    self.title_bar:setTitle(title)
    UIManager:setDirty(self, "ui", self.frame.dimen)
    UIManager:forceRePaint()
end

function AppStoreProgress:cancelled()
    return self._cancelled
end

function AppStoreProgress:cancel()
    if self._cancelled then
        return
    end
    self._cancelled = true
    if self.cancel_callback then
        self.cancel_callback()
    end
    -- Left on screen: the work stops at the next checkpoint, not here, and a dialog that
    -- vanishes while the interface is still busy reads as a freeze.
    self.title_bar:setTitle(self.stopping_title or self.title or "")
    UIManager:setDirty(self, "ui", self.frame.dimen)
    UIManager:forceRePaint()
end

-- Returns true so the key that cancelled is consumed here: unhandled, it would travel on
-- to the browser underneath and close that too.
AppStoreProgress.onClose = function(self)
    self:cancel()
    return true
end
-- Only taps inside the frame arrive here, the GestureRange sees to that, and they are
-- swallowed: the cross in the title bar carries its own callback.
AppStoreProgress.onTapClose = function()
    return true
end

return AppStoreProgress
