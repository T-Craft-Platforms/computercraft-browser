function loadDocumentWithAbort(tab, normalized, allowFallback, requestOptions)
    if not parallel or not parallel.waitForAny then
        local body, finalUrl, headers, err = fetchTextResource(normalized, allowFallback, requestOptions)
        if not body then
            finalUrl = normalized
            body = makeErrorPage(finalUrl, err or "Unknown error")
            headers = { ["Content-Type"] = "text/html" }
        end

        local contentType = getHeader(headers, "Content-Type") or ""
        if not looksLikeHtml(body, contentType) then
            body = "<html><body><pre>" .. escapeHtml(body) .. "</pre></body></html>"
        end
        local aboutUpdateIntervalMs = parseAboutUpdateIntervalMs(headers)
        local settingsStickyStatus = parseSettingsStatusMessage(headers, finalUrl or normalized)

        return {
            finalUrl = finalUrl,
            document = buildDocument(body, finalUrl),
            aboutUpdateIntervalMs = aboutUpdateIntervalMs,
            settingsStickyStatus = settingsStickyStatus,
        }, false
    end

    local result = nil
    local done = false
    local aborted = false

    local function loadTask()
        local ok, errMsg = pcall(function()
            local body, finalUrl, headers, err = fetchTextResource(normalized, allowFallback, requestOptions)
            if not body then
                finalUrl = normalized
                body = makeErrorPage(finalUrl, err or "Unknown error")
                headers = { ["Content-Type"] = "text/html" }
            end

            local contentType = getHeader(headers, "Content-Type") or ""
            if not looksLikeHtml(body, contentType) then
                body = "<html><body><pre>" .. escapeHtml(body) .. "</pre></body></html>"
            end
            local aboutUpdateIntervalMs = parseAboutUpdateIntervalMs(headers)
            local settingsStickyStatus = parseSettingsStatusMessage(headers, finalUrl or normalized)

            result = {
                finalUrl = finalUrl,
                document = buildDocument(body, finalUrl),
                aboutUpdateIntervalMs = aboutUpdateIntervalMs,
                settingsStickyStatus = settingsStickyStatus,
            }
        end)

        if not ok then
            local safeError = tostring(errMsg)
            log("document load task failed: " .. tostring(normalized) .. " (" .. safeError .. ")", LogLevel.error)
            local finalUrl = normalized
            local body = makeErrorPage(finalUrl, safeError)
            result = {
                finalUrl = finalUrl,
                document = buildDocument(body, finalUrl),
            }
        end

        done = true
    end

    local function watchTask()
        while not done do
            local event = { os.pullEvent() }
            local name = event[1]
            if name == "mouse_click" then
                local x = event[3]
                local y = event[4]
                if tab == activeTab() and hitRegion(x, y, state.ui.reload) then
                    aborted = true
                    return
                end
            elseif name == "key" then
                if event[2] == keys.escape then
                    aborted = true
                    return
                end
            elseif name == "timer" then
                if state.animationTimer and event[2] == state.animationTimer then
                    state.animationTimer = nil
                    if scheduleAnimationTick then
                        scheduleAnimationTick()
                    end
                    draw()
                end
            elseif name == "term_resize" then
                rerenderAllTabs()
                draw()
            end
        end
    end

    parallel.waitForAny(loadTask, watchTask)
    if scheduleAnimationTick then
        scheduleAnimationTick()
    end
    return result, aborted
end

function isLuaUrl(url)
    local raw = tostring(url or "")
    local stripped = raw:gsub("[?#].*$", "")
    if stripped:lower():match("%.lua$") ~= nil then
        return true
    end
    if startsWith(stripped:lower(), "about:") then
        local pageName = stripped:match("^about:([^/?#]+)") or ""
        if pageName ~= "" then
            local aboutLuaPath = fs.combine(fs.combine(SCRIPT_DIR, "about-pages"), pageName .. ".lua")
            return fs.exists(aboutLuaPath) and not fs.isDir(aboutLuaPath)
        end
    end
    return false
end

function buildLuaSourceHtml(url, body, heading, statusLine, options)
    local opts = options or {}
    local executionBar = ""
    if opts.executable then
        local sandboxedUrl = makeAppletActionUrl("run", { mode = "sandboxed" })
        local systemUrl = makeAppletActionUrl("run", { mode = "system" })
        executionBar = "<div style=\"position:sticky;top:0;background-color:lightGray;color:black;padding:0 1;\">"
            .. "<p><b>This file is executable.</b></p>"
            .. "<p><a href=\"" .. escapeHtml(sandboxedUrl) .. "\">[Run Sandboxed]</a> "
            .. "<a href=\"" .. escapeHtml(systemUrl) .. "\" style=\"color:red;\"><b>[Run on System]</b></a></p>"
            .. "</div><hr>"
    end

    local statusSection = ""
    if statusLine and statusLine ~= "" then
        statusSection = "<p><i>" .. escapeHtml(statusLine) .. "</i></p><hr>"
    end

    return "<html><body>" .. executionBar
        .. "<h3>" .. escapeHtml(heading) .. "</h3>"
        .. statusSection
        .. "<pre>" .. escapeHtml(body) .. "</pre></body></html>"
end

local APPLET_ACTION_PREFIX = "ccbrowser-applet"

function makeAppletActionUrl(action, params)
    local parts = { "action=" .. urlEncode(tostring(action or "")) }
    for key, value in pairs(params or {}) do
        parts[#parts + 1] = urlEncode(tostring(key or "")) .. "=" .. urlEncode(tostring(value or ""))
    end
    return "#" .. APPLET_ACTION_PREFIX .. "?" .. table.concat(parts, "&")
end

function decodeQueryComponent(value)
    local text = tostring(value or "")
    text = text:gsub("+", " ")
    return core.decodeUrlPath(text)
end

function parseAppletActionUrl(url)
    local raw = tostring(url or "")
    local marker = "#" .. APPLET_ACTION_PREFIX
    local lowered = raw:lower()
    local markerPos = lowered:find(marker, 1, true)
    if not markerPos then
        return nil, {}
    end
    local remainder = raw:sub(markerPos + #marker)
    local query = ""
    if remainder:sub(1, 1) == "?" then
        query = remainder:sub(2)
    end
    local params = {}
    for token in query:gmatch("([^&]+)") do
        local key, value = token:match("^([^=]+)=(.*)$")
        if not key then
            key = token
            value = ""
        end
        key = decodeQueryComponent(key):lower()
        value = decodeQueryComponent(value)
        if key ~= "" then
            params[key] = value
        end
    end
    local action = trim(tostring(params.action or "")):lower()
    return action, params
end

function normalizeAppletMode(rawMode)
    local mode = trim(tostring(rawMode or "")):lower()
    if mode == "system" or mode == "run_on_system" or mode == "unsandboxed" then
        return "system"
    end
    return "sandboxed"
end

function packEvent(...)
    return {
        n = select("#", ...),
        ...,
    }
end

function cloneEvent(event)
    local count = tonumber(event and event.n) or #(event or {})
    local copied = { n = count }
    for i = 1, count do
        copied[i] = event[i]
    end
    return copied
end

function ensureAppletWindowForTab(tab, clearContent)
    local target = tab or activeTab()
    local applet = target and target.applet or nil
    if not applet then
        return nil
    end

    local w, h = term.getSize()
    local topRows = effectiveTopBarRows()
    local contentHeight = math.max(1, h - topRows)
    local created = false

    if not applet.window then
        if window and window.create then
            applet.window = window.create(term.current(), 1, topRows + 1, w, contentHeight, true)
        else
            applet.window = term.current()
        end
        created = true
    elseif applet.window.reposition then
        pcall(applet.window.reposition, 1, topRows + 1, w, contentHeight)
    end

    applet.topRows = topRows
    applet.width = w
    applet.height = contentHeight

    if applet.window then
        if applet.window.setVisible then
            local shouldShow = (target == activeTab()) and not state.menuOpen and not state.modal.open
            pcall(applet.window.setVisible, shouldShow and true or false)
        end
        if (created or clearContent) and applet.window.setBackgroundColor and applet.window.clear then
            local bg = target.pageDefaultBackground or currentDefaultBackgroundColorValue()
            local fg = target.pageDefaultForeground or currentDefaultForegroundColorValue(bg)
            pcall(applet.window.setBackgroundColor, bg)
            pcall(applet.window.setTextColor, fg)
            pcall(applet.window.clear)
            pcall(applet.window.setCursorPos, 1, 1)
        end
    end

    return applet.window
end

stopAppletForTab = function(tab, silent)
    local target = tab or activeTab()
    if not target or not target.applet then
        return false
    end
    local applet = target.applet
    if applet.session and not applet.session.done and type(applet.session.terminate) == "function" then
        pcall(applet.session.terminate)
    end
    if applet.window and applet.window.setVisible then
        pcall(applet.window.setVisible, false)
    end
    target.applet = nil
    if not silent then
        target.status = "Applet stopped"
    end
    return true
end

activeAppletRunning = function()
    local tab = activeTab()
    local applet = tab and tab.applet or nil
    return not not (applet and applet.running and applet.session and not applet.session.done)
end

function finalizeAppletForTab(tab)
    local target = tab or activeTab()
    local applet = target and target.applet or nil
    if not applet or not applet.session or not applet.session.done then
        return false
    end

    local sourceUrl = tostring(applet.sourceUrl or target.currentUrl or "")
    local sourceCode = tostring(applet.sourceCode or "")
    local mode = tostring(applet.mode or "sandboxed")
    local runOk = not (applet.session.ok == false)
    local runErr = tostring(applet.session.error or "")

    if applet.window and applet.window.setVisible then
        pcall(applet.window.setVisible, false)
    end
    target.applet = nil
    target.pendingApplet = {
        sourceUrl = sourceUrl,
        sourceCode = sourceCode,
        addToHistory = false,
        trackHistory = shouldTrackNavigationInHistory(sourceUrl),
        tabHistoryCommitted = true,
        browserHistoryCommitted = true,
        historyCommitted = true,
    }

    local statusLine = nil
    if not runOk then
        statusLine = "Execution failed (" .. mode .. "): " .. runErr
        log("applet execution failed (" .. tostring(mode) .. "): " .. tostring(runErr), LogLevel.error)
    else
        log("applet execution finished (" .. tostring(mode) .. "): " .. tostring(sourceUrl), LogLevel.info)
    end

    target.document = buildDocument(
        buildLuaSourceHtml(sourceUrl, sourceCode, "Lua Applet", statusLine, { executable = true }),
        sourceUrl
    )
    target.currentUrl = sourceUrl
    target.urlInput = sourceUrl
    target.urlCursor = #target.urlInput + 1
    target.urlOffset = 0
    target.urlFocus = false
    clearUrlSelection(target)
    clearPageSelection(target)
    target.formState = {}
    target.formMeta = nil
    target.focusedFormControl = nil
    target.renderRevision = 0
    target.lastRenderSignature = nil
    target.aboutUpdateIntervalMs = nil
    target.settingsStickyStatus = nil
    target.scroll = 0
    target.status = runOk and ("Lua Applet: " .. sourceUrl) or ("Lua Applet error: " .. runErr)
    renderDocument(target)
    return true
end

function startLuaAppletSession(luaSource, sourceUrl, mode, tab)
    local target = tab or activeTab()
    stopAppletForTab(target, true)

    target.applet = {
        running = true,
        mode = mode,
        sourceUrl = sourceUrl,
        sourceCode = luaSource,
        session = nil,
        window = nil,
        pausedEvents = {},
        topRows = effectiveTopBarRows(),
    }

    local contentWindow = ensureAppletWindowForTab(target, true)
    if not contentWindow then
        target.applet = nil
        log("applet start failed: window init failed for " .. tostring(sourceUrl), LogLevel.error)
        return false, "Could not initialize applet window"
    end

    local session, sessionErr = sandbox.createAppletSession(luaSource, sourceUrl, mode, contentWindow)
    if not session then
        target.applet = nil
        log("applet start failed (" .. tostring(mode) .. "): " .. tostring(sessionErr), LogLevel.error)
        return false, tostring(sessionErr or "Unknown applet startup error")
    end

    target.applet.session = session
    if session.done then
        finalizeAppletForTab(target)
        return true, nil
    end
    target.status = "Lua applet running (" .. mode .. "): " .. sourceUrl
    log("applet started (" .. tostring(mode) .. "): " .. tostring(sourceUrl), LogLevel.info)
    return true, nil
end

function commitPendingAppletHistory(tab, label)
    local target = tab or activeTab()
    local pending = target and target.pendingApplet or nil
    if not pending then
        return
    end

    if not pending.tabHistoryCommitted then
        if pending.addToHistory then
            pushHistory(target, pending.sourceUrl)
        elseif target.historyIndex > 0 then
            target.history[target.historyIndex] = pending.sourceUrl
        else
            pushHistory(target, pending.sourceUrl)
        end
        pending.tabHistoryCommitted = true
    end

    if pending.trackHistory and not pending.browserHistoryCommitted then
        addBrowserHistory(pending.sourceUrl, label or ("Lua Applet: " .. pending.sourceUrl))
        pending.browserHistoryCommitted = true
    end

    if pending.tabHistoryCommitted and ((not pending.trackHistory) or pending.browserHistoryCommitted) then
        pending.historyCommitted = true
    end
end

function handleAppletActionNavigation(url, tab)
    local target = tab or activeTab()
    local action, params = parseAppletActionUrl(url)
    local pending = target.pendingApplet
    if not pending then
        local message = "No pending applet action in this tab."
        log("applet action ignored: " .. tostring(message), LogLevel.warn)
        target.loading = false
        target.document = buildDocument(makeErrorPage(url, message), url)
        target.currentUrl = url
        target.urlInput = url
        target.urlCursor = #target.urlInput + 1
        target.urlOffset = 0
        target.status = message
        target.renderRevision = 0
        target.lastRenderSignature = nil
        target.scroll = 0
        renderDocument(target)
        draw()
        return false
    end

    local sourceUrl = pending.sourceUrl
    local sourceCode = pending.sourceCode
    local selectedAction = action ~= "" and action or "view_source"

    if selectedAction == "run" then
        local mode = normalizeAppletMode(params.mode)
        log("applet action run requested (" .. tostring(mode) .. "): " .. tostring(sourceUrl), LogLevel.info)
        commitPendingAppletHistory(target, "Lua Applet: " .. sourceUrl)
        target.pendingApplet = {
            sourceUrl = sourceUrl,
            sourceCode = sourceCode,
            addToHistory = false,
            trackHistory = pending.trackHistory,
            tabHistoryCommitted = true,
            browserHistoryCommitted = true,
            historyCommitted = true,
        }

        local started, startErr = startLuaAppletSession(sourceCode, sourceUrl, mode, target)
        if started then
            target.document = buildDocument("<html><body></body></html>", sourceUrl)
            target.status = "Lua applet running (" .. mode .. "): " .. sourceUrl
        else
            log("applet run request failed (" .. tostring(mode) .. "): " .. tostring(startErr), LogLevel.error)
            target.document = buildDocument(
                buildLuaSourceHtml(
                    sourceUrl,
                    sourceCode,
                    "Lua Applet",
                    "Execution failed (" .. mode .. "): " .. tostring(startErr),
                    { executable = true }
                ),
                sourceUrl
            )
            target.status = "Lua applet failed: " .. tostring(startErr)
        end
    else
        log("applet action view source: " .. tostring(sourceUrl), LogLevel.info)
        commitPendingAppletHistory(target, "Lua Source: " .. sourceUrl)
        target.pendingApplet = {
            sourceUrl = sourceUrl,
            sourceCode = sourceCode,
            addToHistory = false,
            trackHistory = pending.trackHistory,
            tabHistoryCommitted = true,
            browserHistoryCommitted = true,
            historyCommitted = true,
        }
        target.document = buildDocument(
            buildLuaSourceHtml(sourceUrl, sourceCode, "Lua Source", nil, { executable = true }),
            sourceUrl
        )
        target.status = sourceUrl
    end

    target.loading = false
    target.currentUrl = sourceUrl
    target.urlInput = sourceUrl
    target.urlCursor = #target.urlInput + 1
    target.urlOffset = 0
    target.urlFocus = false
    clearUrlSelection(target)
    clearPageSelection(target)
    target.formState = {}
    target.formMeta = nil
    target.focusedFormControl = nil
    target.renderRevision = 0
    target.lastRenderSignature = nil
    target.aboutUpdateIntervalMs = nil
    target.settingsStickyStatus = nil
    target.scroll = 0
    renderDocument(target)
    draw()
    if scheduleAboutUpdateTimer then
        scheduleAboutUpdateTimer()
    end
    return true
end

function mapEventForApplet(target, event)
    local eventName = event[1]
    if eventName == "term_resize" then
        ensureAppletWindowForTab(target, false)
        return cloneEvent(event)
    end

    if eventName == "mouse_click" or eventName == "mouse_drag" or eventName == "mouse_up" or eventName == "mouse_scroll" then
        local x = tonumber(event[3]) or 1
        local y = tonumber(event[4]) or 1
        local topRows = effectiveTopBarRows()
        local _, h = term.getSize()
        local contentHeight = math.max(1, h - topRows)
        if y <= topRows then
            return nil
        end
        local mappedY = y - topRows
        if mappedY < 1 or mappedY > contentHeight then
            return nil
        end
        return packEvent(eventName, event[2], x, mappedY)
    end

    return cloneEvent(event)
end

function appletHandlesBackgroundEvent(name)
    if name == "mouse_click"
        or name == "mouse_drag"
        or name == "mouse_up"
        or name == "mouse_scroll"
        or name == "key"
        or name == "key_up"
        or name == "char"
        or name == "paste" then
        return false
    end
    return true
end

function appletRunningInTab(tab)
    local applet = tab and tab.applet or nil
    return not not (applet and applet.running and applet.session and not applet.session.done)
end

function isBrowserManagedTimerId(timerId)
    if state.animationTimer and timerId == state.animationTimer then
        return true
    end
    local aboutUpdate = state.aboutUpdate
    if aboutUpdate and aboutUpdate.timer and timerId == aboutUpdate.timer then
        return true
    end
    return false
end

function deliverEventToAppletTab(tab, event)
    if not appletRunningInTab(tab) then
        return false
    end

    local applet = tab.applet
    local mapped = mapEventForApplet(tab, event)
    if not mapped then
        return false
    end

    applet.session.deliverEvent(mapped)
    if applet.session.done then
        finalizeAppletForTab(tab)
    end
    return true
end

function enqueuePausedAppletEvent(tab, event)
    if not appletRunningInTab(tab) then
        return false
    end

    local eventName = event and event[1] or nil
    if eventName == "timer" and isBrowserManagedTimerId(event[2]) then
        return false
    end

    local applet = tab.applet
    local queue = applet.pausedEvents
    if type(queue) ~= "table" then
        queue = {}
        applet.pausedEvents = queue
    end

    if #queue >= PAUSED_APPLET_EVENT_MAX then
        return true
    end

    queue[#queue + 1] = cloneEvent(event)
    return true
end

flushPausedAppletQueue = function(tab, maxEvents)
    local target = tab or activeTab()
    if not appletRunningInTab(target) then
        return 0
    end

    local applet = target.applet
    local queue = applet.pausedEvents
    if type(queue) ~= "table" or #queue == 0 then
        return 0
    end

    local remaining = tonumber(maxEvents) or #queue
    remaining = math.max(0, math.floor(remaining))
    local processed = 0

    while remaining > 0 do
        if not appletRunningInTab(target) then
            break
        end

        local currentQueue = target.applet and target.applet.pausedEvents or nil
        if type(currentQueue) ~= "table" or #currentQueue == 0 then
            break
        end

        local queuedEvent = table.remove(currentQueue, 1)
        if not queuedEvent then
            break
        end

        deliverEventToAppletTab(target, queuedEvent)
        processed = processed + 1
        remaining = remaining - 1
    end

    return processed
end

dispatchEventToActiveApplet = function(event)
    return deliverEventToAppletTab(activeTab(), event)
end

function dispatchEventToBackgroundApplets(event)
    local name = event and event[1] or nil
    if not appletHandlesBackgroundEvent(name) then
        return false
    end

    local delivered = false
    local activeIndex = state.activeTab
    local pauseInactive = pauseInactiveAppletsEnabled()
    for index = 1, #state.tabs do
        if index ~= activeIndex then
            local tab = state.tabs[index]
            if appletRunningInTab(tab) then
                if pauseInactive then
                    if enqueuePausedAppletEvent(tab, event) then
                        delivered = true
                    end
                else
                    flushPausedAppletQueue(tab, PAUSED_APPLET_EVENT_MAX)
                    if deliverEventToAppletTab(tab, event) then
                        delivered = true
                    end
                end
            end
        end
    end
    return delivered
end

function finalizeNavigationRender(target)
    target.scroll = 0
    renderDocument(target)
    draw()
    if scheduleAboutUpdateTimer then
        scheduleAboutUpdateTimer()
    end
end

function applyLoadedDocumentToTab(target, finalUrl, document, aboutUpdateIntervalMs, settingsStickyStatus)
    target.document = document
    target.currentUrl = finalUrl
    target.urlInput = finalUrl
    target.urlCursor = #target.urlInput + 1
    target.urlOffset = 0
    target.status = target.document.title or ""
    target.urlFocus = false
    clearUrlSelection(target)
    clearPageSelection(target)
    target.formState = {}
    target.formMeta = nil
    target.focusedFormControl = nil
    target.renderRevision = 0
    target.lastRenderSignature = nil
    target.aboutUpdateIntervalMs = aboutUpdateIntervalMs
    target.settingsStickyStatus = settingsStickyStatus
    target.pendingApplet = nil
end

function commitTabHistoryUrl(target, addToHistory, url)
    if addToHistory then
        pushHistory(target, url)
    elseif target.historyIndex > 0 then
        target.history[target.historyIndex] = url
    else
        pushHistory(target, url)
    end
end

function handleLuaNavigation(target, normalized, allowFallback, requestOptions, addToHistory)
    local body, finalUrl, _, err = fetchTextResource(normalized, allowFallback, requestOptions)
    target.loading = false

    if not body then
        log("lua fetch failed: " .. tostring(normalized) .. " (" .. tostring(err or "Unknown error") .. ")", LogLevel.warn)
        local errUrl = normalized
        local errDocument = buildDocument(makeErrorPage(errUrl, err or "Unknown error"), errUrl)
        applyLoadedDocumentToTab(target, errUrl, errDocument, nil, nil)
        if addToHistory then
            pushHistory(target, errUrl)
        end
        finalizeNavigationRender(target)
        return false
    end

    local resolvedUrl = finalUrl or normalized
    local pendingApplet = {
        sourceUrl = resolvedUrl,
        sourceCode = body,
        addToHistory = addToHistory == true,
        trackHistory = shouldTrackNavigationInHistory(normalized),
        tabHistoryCommitted = false,
        browserHistoryCommitted = false,
        historyCommitted = false,
    }
    commitTabHistoryUrl(target, addToHistory, resolvedUrl)
    pendingApplet.tabHistoryCommitted = true

    local promptDocument = buildDocument(
        buildLuaSourceHtml(resolvedUrl, body, "Lua Source", nil, { executable = true }),
        resolvedUrl
    )
    applyLoadedDocumentToTab(target, resolvedUrl, promptDocument, nil, nil)
    target.pendingApplet = pendingApplet
    target.status = "Executable detected: " .. resolvedUrl
    log("lua source loaded: " .. tostring(resolvedUrl), LogLevel.info)
    finalizeNavigationRender(target)
    return true
end

function handleDocumentNavigation(target, normalized, allowFallback, requestOptions, addToHistory)
    local result, aborted = loadDocumentWithAbort(target, normalized, allowFallback, requestOptions)
    target.loading = false
    if aborted then
        target.status = "Load aborted"
        log("document load aborted: " .. tostring(normalized), LogLevel.warn)
        draw()
        if scheduleAboutUpdateTimer then
            scheduleAboutUpdateTimer()
        end
        return false
    end

    local finalUrl = normalized
    local document = nil
    local aboutUpdateIntervalMs = nil
    local settingsStickyStatus = nil
    if result then
        finalUrl = result.finalUrl or finalUrl
        document = result.document
        aboutUpdateIntervalMs = result.aboutUpdateIntervalMs
        settingsStickyStatus = result.settingsStickyStatus
    end
    if not document then
        log("document render fallback error page: " .. tostring(normalized), LogLevel.warn)
        document = buildDocument(makeErrorPage(normalized, "Unknown error"), normalized)
    end

    applyLoadedDocumentToTab(target, finalUrl, document, aboutUpdateIntervalMs, settingsStickyStatus)
    commitTabHistoryUrl(target, addToHistory, finalUrl)
    if shouldTrackNavigationInHistory(normalized) then
        addBrowserHistory(finalUrl, target.document and target.document.title or "")
    end
    finalizeNavigationRender(target)
    log("document loaded: " .. tostring(finalUrl), LogLevel.info)
    return true
end

navigate = function(rawInput, addToHistory, allowFallback, tab, requestOptions)
    local target = tab or activeTab()
    local normalized, inferred = normalizeInputUrl(rawInput)
    local normalizedLower = trim(tostring(normalized or "")):lower()
    local shouldAllowFallback = allowFallback or inferred
    log("navigate " .. tostring(normalized), LogLevel.info)
    state.highUsage.loadingFrame = true

    stopAppletForTab(target, true)
    target.loading = true
    target.status = "Loading " .. normalized
    target.urlInput = normalized
    target.urlCursor = #target.urlInput + 1
    target.urlOffset = 0
    clearUrlSelection(target)
    draw()

    if isLuaUrl(normalized) then
        return handleLuaNavigation(target, normalized, shouldAllowFallback, requestOptions, addToHistory)
    end
    return handleDocumentNavigation(target, normalized, shouldAllowFallback, requestOptions, addToHistory)
end

function goBack()
    local tab = activeTab()
    if not canGoBack(tab) then
        return
    end
    tab.historyIndex = tab.historyIndex - 1
    navigate(tab.history[tab.historyIndex], false, false, tab)
end

function goForward()
    local tab = activeTab()
    if not canGoForward(tab) then
        return
    end
    tab.historyIndex = tab.historyIndex + 1
    navigate(tab.history[tab.historyIndex], false, false, tab)
end

function reloadPage()
    local tab = activeTab()
    if tab.loading then
        return
    end
    if not tab.currentUrl then
        return
    end
    navigate(tab.currentUrl, false, false, tab)
end

function insertUrlText(text)
    local tab = activeTab()
    if not tab.urlFocus then
        return
    end
    deleteUrlSelection(tab)
    local before = tab.urlInput:sub(1, tab.urlCursor - 1)
    local after = tab.urlInput:sub(tab.urlCursor)
    tab.urlInput = before .. text .. after
    tab.urlCursor = tab.urlCursor + #text
    clearUrlSelection(tab)
end

function deleteUrlBack()
    local tab = activeTab()
    if deleteUrlSelection(tab) then
        return
    end
    if tab.urlCursor <= 1 then
        return
    end
    local before = tab.urlInput:sub(1, tab.urlCursor - 2)
    local after = tab.urlInput:sub(tab.urlCursor)
    tab.urlInput = before .. after
    tab.urlCursor = tab.urlCursor - 1
end

function deleteUrlForward()
    local tab = activeTab()
    if deleteUrlSelection(tab) then
        return
    end
    if tab.urlCursor > #tab.urlInput then
        return
    end
    local before = tab.urlInput:sub(1, tab.urlCursor - 1)
    local after = tab.urlInput:sub(tab.urlCursor + 1)
    tab.urlInput = before .. after
end

