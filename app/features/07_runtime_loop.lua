function bootstrap(initialUrls, startupFullscreenMode, startupMonitorChoice)
    if state.initialTermBackground == nil and NATIVE_TERM and NATIVE_TERM.getBackgroundColor then
        state.initialTermBackground = NATIVE_TERM.getBackgroundColor()
    end
    if state.initialTermForeground == nil and NATIVE_TERM and NATIVE_TERM.getTextColor then
        state.initialTermForeground = NATIVE_TERM.getTextColor()
    end

    displayManager.setStartupMonitorChoice(startupMonitorChoice)
    local okDisplay, displayErr = refreshDisplayTarget()
    if not okDisplay and displayErr and displayErr ~= "" then
        log(displayErr, LogLevel.warn)
    end

    local bg = currentDefaultBackgroundColorValue()
    local fg = currentDefaultForegroundColorValue(bg)
    term.setBackgroundColor(bg)
    term.setTextColor(fg)
    term.clear()
    term.setCursorPos(1, 1)

    if startupFullscreenMode == "seamless" then
        state.fullscreen = true
        state.seamlessAppletFullscreen = true
        state.menuOpen = false
    elseif startupFullscreenMode == "normal" then
        state.fullscreen = true
        state.seamlessAppletFullscreen = false
        state.menuOpen = false
    end

    scheduleAnimationTick()

    if not initialUrls or #initialUrls == 0 then
        local homePage = homePageUrl()
        navigate(homePage, true, true, activeTab())
        if scheduleAboutUpdateTimer then
            scheduleAboutUpdateTimer()
        end
        return
    end

    for i, url in ipairs(initialUrls) do
        local tab = nil
        if i == 1 then
            tab = activeTab()
        else
            tab = newTab(homePageUrl())
        end
        navigate(url, true, true, tab)
    end
    activateTab(1)
    draw()
    if scheduleAboutUpdateTimer then
        scheduleAboutUpdateTimer()
    end
end

function appletMouseHandledByBrowser(eventName, x, y)
    if seamlessAppletFullscreenActive and seamlessAppletFullscreenActive() then
        return false
    end
    if state.menuOpen then
        return true
    end
    if state.tabDrag or state.scrollbarDrag then
        return true
    end
    if state.fullscreen then
        layoutUi()
        if hitRegion(x, y, state.ui.menuButton) then
            return true
        end
        return false
    end
    return y <= effectiveTopBarRows()
end

function handleEventWithoutApplet(event)
    if event[1] == "mouse_click" then
        handleMouseClick(event[2], event[3], event[4])
    elseif event[1] == "mouse_drag" then
        handleMouseDrag(event[2], event[3], event[4])
    elseif event[1] == "mouse_up" then
        handleMouseUp(event[2], event[3], event[4])
    elseif event[1] == "mouse_scroll" then
        handleMouseScroll(event[2], event[3], event[4])
    elseif event[1] == "key" then
        handleKeyDown(event[2])
    elseif event[1] == "key_up" then
        handleKeyUp(event[2])
    elseif event[1] == "char" then
        handleChar(event[2])
    elseif event[1] == "paste" then
        handlePaste(event[2])
    elseif event[1] == "timer" then
        handleTimer(event[2])
    elseif event[1] == "term_resize" then
        rerenderAllTabs()
    end
end

function handleAppletMouseEvent(name, event)
    if appletMouseHandledByBrowser(name, event[3], event[4]) then
        if name == "mouse_click" then
            handleMouseClick(event[2], event[3], event[4])
        elseif name == "mouse_drag" then
            handleMouseDrag(event[2], event[3], event[4])
        elseif name == "mouse_up" then
            handleMouseUp(event[2], event[3], event[4])
        else
            handleMouseScroll(event[2], event[3], event[4])
        end
    else
        dispatchEventToActiveApplet(event)
    end
end

function handleEventWithApplet(event)
    if seamlessAppletFullscreenActive and seamlessAppletFullscreenActive() then
        if event[1] == "mouse_click" or event[1] == "mouse_drag" or event[1] == "mouse_up" or event[1] == "mouse_scroll" then
            dispatchEventToActiveApplet(event)
            return
        end
        if event[1] == "key" then
            if event[2] == keys.leftCtrl or event[2] == keys.rightCtrl then
                state.ctrlDown = true
                dispatchEventToActiveApplet(event)
                return
            end
            if state.ctrlDown and event[2] == keys.k then
                toggleFullscreen(true)
                return
            end
            dispatchEventToActiveApplet(event)
            return
        end
        if event[1] == "key_up" then
            handleKeyUp(event[2])
            dispatchEventToActiveApplet(event)
            return
        end
        if event[1] == "paste" then
            dispatchEventToActiveApplet(event)
            return
        end
        if event[1] == "timer" then
            handleTimer(event[2])
            dispatchEventToActiveApplet(event)
            return
        end
        if event[1] == "term_resize" then
            rerenderAllTabs()
            dispatchEventToActiveApplet(event)
            return
        end
        dispatchEventToActiveApplet(event)
        return
    end

    if event[1] == "mouse_click" or event[1] == "mouse_drag" or event[1] == "mouse_up" or event[1] == "mouse_scroll" then
        handleAppletMouseEvent(event[1], event)
        return
    end

    if event[1] == "key" then
        handleKeyDown(event[2], true)
        if event[2] ~= keys.f5
            and event[2] ~= keys.f7
            and event[2] ~= keys.escape
            and not (state.ctrlDown and event[2] ~= keys.leftCtrl and event[2] ~= keys.rightCtrl) then
            dispatchEventToActiveApplet(event)
        end
        return
    end

    if event[1] == "key_up" then
        handleKeyUp(event[2])
        dispatchEventToActiveApplet(event)
        return
    end

    if event[1] == "char" then
        if event[2]
            and string.byte(event[2], 1)
            and string.byte(event[2], 1) >= 1
            and string.byte(event[2], 1) <= 31 then
            handleChar(event[2])
        else
            dispatchEventToActiveApplet(event)
        end
        return
    end

    if event[1] == "paste" then
        if state.skipNextPaste then
            state.skipNextPaste = false
        else
            dispatchEventToActiveApplet(event)
        end
        return
    end

    if event[1] == "timer" then
        handleTimer(event[2])
        dispatchEventToActiveApplet(event)
        return
    end

    if event[1] == "term_resize" then
        rerenderAllTabs()
        dispatchEventToActiveApplet(event)
        return
    end

    dispatchEventToActiveApplet(event)
end

function processFrameAfterEvent(frameStart)
    if activeAppletRunning() then
        if flushPausedAppletQueue then
            flushPausedAppletQueue(activeTab(), PAUSED_APPLET_FLUSH_PER_FRAME)
        end
        ensureAppletWindowForTab(activeTab(), false)
    else
        renderDocument(activeTab())
    end
    draw()

    state.highUsage.lastFrameMs = (os.clock() - frameStart) * 1000

    if state.highUsage.intentionalUiBreak then
        state.highUsage.intentionalUiBreak = false
        state.highUsage.overCount = 0
        state.highUsage.frozen = false
        state.highUsage.cooldownUntil = os.clock() + HIGH_USAGE_COOLDOWN_SECONDS
        return
    end

    if state.modal.open then
        local spec = state.modal.spec
        if not (spec and spec.id == "high_usage_guard") then
            state.highUsage.overCount = 0
            state.highUsage.frozen = false
            return
        end
    end

    if usageGuardEnabled() then
        if os.clock() < (state.highUsage.cooldownUntil or 0) then
            state.highUsage.overCount = 0
        elseif state.highUsage.lastFrameMs >= (
                state.highUsage.loadingFrame and HIGH_USAGE_FRAME_THRESHOLD_LOADING_MS or HIGH_USAGE_FRAME_THRESHOLD_MS
            ) then
            state.highUsage.overCount = (state.highUsage.overCount or 0) + 1
            if state.highUsage.overCount >= HIGH_USAGE_STRIKE_LIMIT then
                activateUsageGuard(state.highUsage.lastFrameMs)
            end
        else
            state.highUsage.overCount = 0
        end
    else
        state.highUsage.overCount = 0
        state.highUsage.frozen = false
        if state.modal.open and state.modal.spec and state.modal.spec.id == "high_usage_guard" then
            clearModal()
        end
    end
end

function processBrowserEvent(event, frameStart)
    if displayManager.getRuntimeDisplayTarget() ~= INTERNAL_MONITOR_ID
        and event[5] ~= "monitor_touch"
        and (event[1] == "mouse_click" or event[1] == "mouse_drag" or event[1] == "mouse_up" or event[1] == "mouse_scroll") then
        if event[1] == "mouse_click" then
            handleNativeMonitorControlClick(event[2], event[3], event[4])
        end
        if state.running then
            draw()
        end
        return
    end

    if state.modal.open then
        handleModalEvent(event)
        dispatchEventToBackgroundApplets(event)
        if (not pauseInactiveAppletsEnabled())
            and activeAppletRunning()
            and appletHandlesBackgroundEvent(event and event[1] or nil) then
            dispatchEventToActiveApplet(event)
        end
        if state.running then
            draw()
        end
        return
    end

    if activeAppletRunning() then
        handleEventWithApplet(event)
    else
        handleEventWithoutApplet(event)
    end
    dispatchEventToBackgroundApplets(event)

    processFrameAfterEvent(frameStart)
end

function processNextBrowserEvent()
    if scheduleAnimationTick then
        scheduleAnimationTick()
    end
    state.lastPulledEvent = { os.pullEvent() }
    if state.lastPulledEvent[1] == "monitor_touch" then
        local monitorPeripheral = displayManager.getRuntimeDisplayMonitorPeripheral()
        if monitorPeripheral and state.lastPulledEvent[2] == monitorPeripheral then
            state.lastPulledEvent = { "mouse_click", 1, state.lastPulledEvent[3], state.lastPulledEvent[4], "monitor_touch" }
        end
    elseif state.lastPulledEvent[1] == "peripheral_detach" or state.lastPulledEvent[1] == "peripheral" then
        local monitorPeripheral = displayManager.getRuntimeDisplayMonitorPeripheral()
        if monitorPeripheral and state.lastPulledEvent[2] == monitorPeripheral then
            refreshDisplayTarget()
            if state.running then
                rerenderAllTabs()
                draw()
            end
        end
    end
    state.highUsage.loadingFrame = false

    if state.skipNextPaste and state.lastPulledEvent[1] ~= "paste" and state.lastPulledEvent[1] ~= "key_up" then
        state.skipNextPaste = false
    end

    if state.highUsage.frozen and not state.modal.open then
        state.highUsage.frozen = false
        activateUsageGuard(state.highUsage.lastFrameMs or 0)
    end

    processBrowserEvent(state.lastPulledEvent, os.clock())
    state.lastPulledEvent = nil
    if scheduleAboutUpdateTimer then
        scheduleAboutUpdateTimer()
    end
end

function shutdownBrowserUi()
    term.setCursorBlink(false)
    local bg = state.initialTermBackground or colors.black
    local fg = state.initialTermForeground or colors.white
    displayManager.shutdownDisplay(bg, fg)
    term.setBackgroundColor(bg)
    term.setTextColor(fg)
    term.clear()
    term.setCursorPos(1, 1)
end

function parseStartupArgs(args)
    local initialUrls = {}
    local startupFullscreenMode = nil
    local startupMonitorChoice = nil
    for i = 1, #(args or {}) do
        local value = tostring(args[i] or "")
        local lowered = value:lower()
        if lowered == "--seamless" then
            startupFullscreenMode = "seamless"
        elseif lowered == "--fullscreen" then
            if startupFullscreenMode ~= "seamless" then
                startupFullscreenMode = "normal"
            end
        elseif lowered:sub(1, #"--monitor=") == "--monitor=" then
            startupMonitorChoice = value:sub(#"--monitor=" + 1)
        elseif value ~= "" then
            initialUrls[#initialUrls + 1] = value
        end
    end
    return initialUrls, startupFullscreenMode, startupMonitorChoice
end

function run(...)
    local rawArgs = { ... }
    local initialUrls, startupFullscreenMode, startupMonitorChoice = parseStartupArgs(rawArgs)
    log("browser start", LogLevel.info)
    bootstrap(initialUrls, startupFullscreenMode, startupMonitorChoice)
    while state.running do
        processNextBrowserEvent()
    end
    log("browser shutdown", LogLevel.info)
    shutdownBrowserUi()
end

return run
