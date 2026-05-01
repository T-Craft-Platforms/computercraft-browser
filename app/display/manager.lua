return function(deps)
    local core = deps.core
    local term = deps.term
    local peripheral = deps.peripheral
    local colors = deps.colors
    local APP_TITLE = tostring(deps.appTitle or "CC Browser")
    local INTERNAL_MONITOR_ID = tostring(deps.internalMonitorId or "internal")
    local INTERNAL_MONITOR_LABEL = tostring(deps.internalMonitorLabel or "Internal Monitor")
    local NATIVE_TERM = deps.nativeTerm
    local browserSettings = deps.browserSettings or {}
    local currentDefaultBackgroundColorValue = deps.currentDefaultBackgroundColorValue
    local currentDefaultForegroundColorValue = deps.currentDefaultForegroundColorValue
    local persistBrowserState = deps.persistBrowserState
    local getState = deps.getState or function()
        return nil
    end

    local runtimeDisplayTarget = INTERNAL_MONITOR_ID
    local runtimeDisplayMonitorPeripheral = nil
    local startupMonitorOverride = nil
    local sessionMonitorOverride = nil

    local function trim(value)
        return core.trim(tostring(value or ""))
    end

    local function callOptional(fn, ...)
        if type(fn) ~= "function" then
            return nil
        end
        return fn(...)
    end

    local function logWarn(message)
        local logFn = deps.log
        local level = deps.logLevelWarn
        callOptional(logFn, tostring(message or ""), level)
    end

    local function normalizeMonitorChoice(value)
        local raw = trim(value)
        local lowered = raw:lower()
        if lowered == "" or lowered == "internal" or lowered == "computer" or lowered == "terminal" then
            return INTERNAL_MONITOR_ID
        end
        return raw
    end

    local function attachedMonitorNames()
        local names = {}
        if peripheral and type(peripheral.getNames) == "function" and type(peripheral.getType) == "function" then
            for _, name in ipairs(peripheral.getNames()) do
                if peripheral.getType(name) == "monitor" then
                    names[#names + 1] = tostring(name)
                end
            end
        end
        table.sort(names)
        return names
    end

    local function monitorExists(name)
        local wanted = tostring(name or "")
        if wanted == "" then
            return false
        end
        for _, monitorName in ipairs(attachedMonitorNames()) do
            if monitorName == wanted then
                return true
            end
        end
        return false
    end

    local function listMonitorTargets()
        local targets = {
            { value = INTERNAL_MONITOR_ID, label = INTERNAL_MONITOR_LABEL },
        }
        for _, name in ipairs(attachedMonitorNames()) do
            targets[#targets + 1] = { value = name, label = name }
        end
        return targets
    end

    local function monitorSurface(choice)
        local normalized = normalizeMonitorChoice(choice)
        if normalized == INTERNAL_MONITOR_ID then
            return NATIVE_TERM
        end
        if peripheral and type(peripheral.wrap) == "function" then
            return peripheral.wrap(normalized)
        end
        return nil
    end

    local function runOnSurface(surface, fn)
        if not surface or type(fn) ~= "function" or not (term and type(term.redirect) == "function") then
            return false
        end
        local previous = term.current and term.current() or nil
        term.redirect(surface)
        local ok, err = pcall(fn)
        if previous then
            term.redirect(previous)
        elseif NATIVE_TERM then
            term.redirect(NATIVE_TERM)
        end
        return ok, err
    end

    local function clearSurface(choice, background, foreground)
        local surface = monitorSurface(choice)
        if not surface then
            return false
        end
        local bg = background or currentDefaultBackgroundColorValue()
        local fg = foreground or currentDefaultForegroundColorValue(bg)
        runOnSurface(surface, function()
            term.setCursorBlink(false)
            term.setBackgroundColor(bg)
            term.setTextColor(fg)
            term.clear()
            term.setCursorPos(1, 1)
        end)
        return true
    end

    local function applyDisplayTarget(choice)
        local normalized = normalizeMonitorChoice(choice)
        local previousTarget = normalizeMonitorChoice(runtimeDisplayTarget or INTERNAL_MONITOR_ID)
        local bg = currentDefaultBackgroundColorValue()
        local fg = currentDefaultForegroundColorValue(bg)
        if previousTarget ~= normalized then
            clearSurface(previousTarget, bg, fg)
        end

        if normalized == INTERNAL_MONITOR_ID then
            if term and type(term.redirect) == "function" and NATIVE_TERM then
                term.redirect(NATIVE_TERM)
            end
            runtimeDisplayTarget = INTERNAL_MONITOR_ID
            runtimeDisplayMonitorPeripheral = nil
            return true, nil
        end

        if not monitorExists(normalized) then
            return false, "Monitor not found: " .. tostring(normalized)
        end
        local wrapped = peripheral and type(peripheral.wrap) == "function" and peripheral.wrap(normalized) or nil
        if not wrapped then
            return false, "Could not access monitor: " .. tostring(normalized)
        end

        if term and type(term.redirect) == "function" then
            term.redirect(wrapped)
        end
        runtimeDisplayTarget = normalized
        runtimeDisplayMonitorPeripheral = normalized
        return true, nil
    end

    local function refreshDisplayTarget()
        local function tryApply(choice)
            local normalized = normalizeMonitorChoice(choice)
            if normalized == INTERNAL_MONITOR_ID then
                return applyDisplayTarget(INTERNAL_MONITOR_ID)
            end
            return applyDisplayTarget(normalized)
        end

        if startupMonitorOverride then
            local okOverride = select(1, tryApply(startupMonitorOverride))
            if okOverride then
                return true, nil
            end
        end

        if sessionMonitorOverride then
            local okSession = select(1, tryApply(sessionMonitorOverride))
            if okSession then
                return true, nil
            end
            sessionMonitorOverride = nil
        end

        local okSetting = select(1, tryApply(browserSettings.default_monitor))
        if okSetting then
            return true, nil
        end

        applyDisplayTarget(INTERNAL_MONITOR_ID)
        if not startupMonitorOverride and browserSettings.default_monitor ~= INTERNAL_MONITOR_ID then
            browserSettings.default_monitor = INTERNAL_MONITOR_ID
            callOptional(persistBrowserState)
        end
        return false, "Display target unavailable; switched to internal monitor."
    end

    local function inRegion(x, y, region)
        if not region then
            return false
        end
        return y == region.y and x >= region.x1 and x <= region.x2
    end

    local function drawNativeMonitorControls()
        local state = getState()
        if not state then
            return
        end

        local controls = state.monitorControls or {}
        state.monitorControls = controls

        if runtimeDisplayTarget == INTERNAL_MONITOR_ID or not NATIVE_TERM then
            controls.visible = false
            controls.switchButton = nil
            controls.exitButton = nil
            return
        end

        runOnSurface(NATIVE_TERM, function()
            local w, h = term.getSize()
            term.setCursorBlink(false)
            term.setBackgroundColor(colors.black)
            term.setTextColor(colors.white)
            term.clear()

            local title = APP_TITLE
            local active = "Showing on: " .. tostring(runtimeDisplayTarget or INTERNAL_MONITOR_ID)
            local helper = startupMonitorOverride and "Display target is locked by startup argument."
                or "Use the buttons below from this terminal."
            term.setCursorPos(math.max(1, math.floor((w - #title) / 2) + 1), math.max(1, math.floor(h / 2) - 3))
            term.write(title:sub(1, w))
            term.setCursorPos(math.max(1, math.floor((w - #active) / 2) + 1), math.max(1, math.floor(h / 2) - 2))
            term.write(active:sub(1, w))
            term.setCursorPos(math.max(1, math.floor((w - #helper) / 2) + 1), math.max(1, math.floor(h / 2) - 1))
            term.write(helper:sub(1, w))

            local function drawButton(y, label, fg, bg)
                local text = " " .. tostring(label or "") .. " "
                if #text > w then
                    text = text:sub(1, w)
                end
                local x1 = math.max(1, math.floor((w - #text) / 2) + 1)
                local x2 = math.min(w, x1 + #text - 1)
                term.setCursorPos(x1, y)
                term.setTextColor(fg)
                term.setBackgroundColor(bg)
                term.write(text)
                return { x1 = x1, x2 = x2, y = y }
            end

            local switchY = math.max(1, math.floor(h / 2) + 1)
            local exitY = math.min(h, switchY + 2)
            if startupMonitorOverride then
                controls.switchButton = nil
            else
                controls.switchButton = drawButton(switchY, "Switch To Internal (One-Time)", colors.black, colors.lime)
            end
            controls.exitButton = drawButton(exitY, "Exit Browser", colors.white, colors.red)
            controls.visible = true
        end)
    end

    local function handleNativeMonitorControlClick(button, x, y)
        local state = getState()
        local controls = state and state.monitorControls or nil
        if runtimeDisplayTarget == INTERNAL_MONITOR_ID or not controls or not controls.visible then
            return false
        end
        if button ~= 1 then
            return true
        end
        if controls.switchButton and inRegion(x, y, controls.switchButton) then
            sessionMonitorOverride = INTERNAL_MONITOR_ID
            local okDisplay, displayErr = refreshDisplayTarget()
            if not okDisplay and displayErr and displayErr ~= "" then
                logWarn(displayErr)
            end
            local onDisplayChanged = deps.onDisplayChanged
            callOptional(onDisplayChanged)
            return true
        end
        if inRegion(x, y, controls.exitButton) then
            local onExitRequested = deps.onExitRequested
            if type(onExitRequested) == "function" then
                onExitRequested()
            elseif state then
                state.running = false
            end
            return true
        end
        return true
    end

    local function setStartupMonitorChoice(choice)
        startupMonitorOverride = normalizeMonitorChoice(choice)
        if startupMonitorOverride == INTERNAL_MONITOR_ID then
            startupMonitorOverride = nil
        end
    end

    local function getStartupMonitorOverride()
        return startupMonitorOverride or ""
    end

    local function clearSessionOverride()
        sessionMonitorOverride = nil
    end

    local function getRuntimeDisplayTarget()
        return runtimeDisplayTarget
    end

    local function getRuntimeDisplayMonitorPeripheral()
        return runtimeDisplayMonitorPeripheral
    end

    local function shutdownDisplay(background, foreground)
        local bg = background or colors.black
        local fg = foreground or colors.white
        clearSurface(runtimeDisplayTarget or INTERNAL_MONITOR_ID, bg, fg)
        clearSurface(INTERNAL_MONITOR_ID, bg, fg)
        if term and type(term.redirect) == "function" and NATIVE_TERM then
            term.redirect(NATIVE_TERM)
        end
    end

    return {
        INTERNAL_MONITOR_ID = INTERNAL_MONITOR_ID,
        INTERNAL_MONITOR_LABEL = INTERNAL_MONITOR_LABEL,
        normalizeMonitorChoice = normalizeMonitorChoice,
        attachedMonitorNames = attachedMonitorNames,
        monitorExists = monitorExists,
        listMonitorTargets = listMonitorTargets,
        applyDisplayTarget = applyDisplayTarget,
        refreshDisplayTarget = refreshDisplayTarget,
        drawNativeMonitorControls = drawNativeMonitorControls,
        handleNativeMonitorControlClick = handleNativeMonitorControlClick,
        setStartupMonitorChoice = setStartupMonitorChoice,
        getStartupMonitorOverride = getStartupMonitorOverride,
        clearSessionOverride = clearSessionOverride,
        getRuntimeDisplayTarget = getRuntimeDisplayTarget,
        getRuntimeDisplayMonitorPeripheral = getRuntimeDisplayMonitorPeripheral,
        shutdownDisplay = shutdownDisplay,
    }
end
