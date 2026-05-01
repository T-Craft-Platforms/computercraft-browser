function homePageUrl()
    local homePage = trim(browserSettings.home_page or "about:home")
    if homePage == "" then
        homePage = "about:home"
    end
    return homePage
end

function usageGuardEnabled()
    return settingEnabledRaw("usage_guard_enabled", true)
end

function pauseInactiveAppletsEnabled()
    return settingEnabledRaw("pause_inactive_applets", true)
end

function seamlessFullscreenSettingEnabled()
    return normalizeFullscreenMode(browserSettings.fullscreen_mode) == "seamless"
end

function seamlessAppletFullscreenActive()
    return state.fullscreen
        and state.seamlessAppletFullscreen
end

local fetchTextResource = network.fetchTextResource
local makeErrorPage = network.makeErrorPage
local looksLikeHtml = network.looksLikeHtml

local createEmptyLine = content.createEmptyLine
local buildDocument = content.buildDocument
local renderDocumentLines = content.renderDocumentLines
local renderDocumentWindowLines = content.renderDocumentWindowLines or function(
    document,
    width,
    startLine,
    lineCount,
    formState,
    focusControlKey
)
    local lines, meta = renderDocumentLines(document, width, formState, focusControlKey)
    local totalLines = math.max(1, #lines)
    return lines, meta, totalLines
end

local TOP_BAR_ROWS = 2

function effectiveTopBarRows()
    return state.fullscreen and 0 or TOP_BAR_ROWS
end
local ANIMATION_TICK_SECONDS = 0.15
local SNACKBAR_DEFAULT_DURATION_MS = 1000
local SNACKBAR_ANIMATION_MS = 180
local SNACKBAR_MAX_WIDTH = 48
local PAUSED_APPLET_EVENT_MAX = 256
local PAUSED_APPLET_FLUSH_PER_FRAME = 48
local HIGH_USAGE_FRAME_THRESHOLD_MS = 750
local HIGH_USAGE_FRAME_THRESHOLD_LOADING_MS = 10000
local HIGH_USAGE_STRIKE_LIMIT = 1
local HIGH_USAGE_COOLDOWN_SECONDS = 2.0
local ABOUT_UPDATE_INTERVAL_HEADER = "X-CC-About-Update-Ms"
local SETTINGS_STATUS_HEADER = "X-CC-Settings-Status"
local scheduleAnimationTick
local stopAppletForTab
local activeAppletRunning
local dispatchEventToActiveApplet

function parseAboutUpdateIntervalMs(headers)
    local raw = getHeader(headers, ABOUT_UPDATE_INTERVAL_HEADER)
    local intervalMs = tonumber(raw)
    if not intervalMs then
        return nil
    end
    intervalMs = math.floor(intervalMs + 0.5)
    if intervalMs < 1 then
        return nil
    end
    return intervalMs
end

function parseSettingsStatusMessage(headers, currentUrl)
    local normalizedUrl = trim(tostring(currentUrl or "")):lower()
    if not startsWith(normalizedUrl, "about:settings") then
        return nil
    end
    local raw = getHeader(headers, SETTINGS_STATUS_HEADER)
    local parsed = trim(tostring(raw or ""))
    if parsed == "" then
        return nil
    end
    return parsed
end

function parseInteger(value, fallback)
    local number = tonumber(value)
    if not number then
        return fallback
    end
    return math.floor(number)
end

function createTab(initialUrl)
    local startingUrl = initialUrl or homePageUrl()
    return {
        currentUrl = startingUrl,
        urlInput = startingUrl,
        urlCursor = #startingUrl + 1,
        urlOffset = 0,
        urlSelStart = nil,
        urlSelEnd = nil,
        urlFocus = false,
        scroll = 0,
        history = {},
        historyIndex = 0,
        document = nil,
        pageLines = { createEmptyLine() },
        pageContentHeight = 1,
        pageWindowStart = 1,
        pageWindowEnd = 1,
        pageDefaultBackground = currentDefaultBackgroundColorValue(),
        pageDefaultForeground = currentDefaultForegroundColorValue(currentDefaultBackgroundColorValue()),
        renderRevision = 0,
        lastRenderSignature = nil,
        viewportWidth = 1,
        showVerticalScrollbar = false,
        pageSelection = nil,
        formState = {},
        formMeta = nil,
        focusedFormControl = nil,
        loading = false,
        status = (not storageReady and tostring(lastStorageError or "")) or "",
        aboutUpdateIntervalMs = nil,
        settingsStickyStatus = nil,
        pendingApplet = nil,
        applet = nil,
    }
end

state = {
    tabs = { createTab(homePageUrl()) },
    activeTab = 1,
    menuOpen = false,
    fullscreen = false,
    seamlessAppletFullscreen = false,
    expandedTabIndex = nil,
    tabDrag = nil,
    scrollbarDrag = nil,
    caretMode = false,
    clipboard = "",
    localClipboardPendingPaste = false,
    skipNextPaste = false,
    lastTabClick = {
        index = nil,
        button = nil,
        at = 0,
    },
    tabTitleCarousel = nil,
    animationTimer = nil,
    snackbar = {
        active = false,
        message = "",
        startedAt = 0,
        durationMs = SNACKBAR_DEFAULT_DURATION_MS,
    },
    aboutUpdate = {
        timer = nil,
        tabIndex = nil,
        intervalMs = nil,
    },
    running = true,
    initialTermBackground = nil,
    initialTermForeground = nil,
    ctrlDown = false,
    shiftDown = false,
    highUsage = {
        frozen = false,
        overCount = 0,
        lastFrameMs = 0,
        cooldownUntil = 0,
        loadingFrame = false,
        intentionalUiBreak = false,
    },
    modal = {
        open = false,
        spec = nil,
        layout = nil,
    },
    ui = {
        tabs = {},
        tabClose = {},
        closeBrowser = { x1 = 1, x2 = 1, y = 1 },
        newTab = { x1 = 1, x2 = 1, y = 1 },
        back = { x1 = 1, x2 = 3, y = 2 },
        forward = { x1 = 5, x2 = 7, y = 2 },
        reload = { x1 = 9, x2 = 11, y = 2 },
        url = { x1 = 13, x2 = 13, y = 2 },
        menuButton = { x1 = 1, x2 = 1, y = 2 },
        menu = nil,
    },
    monitorControls = {
        visible = false,
        switchButton = nil,
        exitButton = nil,
    },
}

local tabState = createTabState({
    state = state,
    clamp = clamp,
    term = term,
    effectiveTopBarRows = effectiveTopBarRows,
    homePageUrl = homePageUrl,
    createTab = createTab,
    createEmptyLine = createEmptyLine,
    buildDocument = buildDocument,
    currentDefaultBackgroundColorValue = currentDefaultBackgroundColorValue,
    currentDefaultForegroundColorValue = currentDefaultForegroundColorValue,
    renderDocumentWindowLines = renderDocumentWindowLines,
    pageOverflowYFromDocument = function(document)
        return document and document.pageOverflowY or "visible"
    end,
    getStopAppletForTab = function()
        return stopAppletForTab
    end,
    getFlushPausedAppletQueue = function()
        return flushPausedAppletQueue
    end,
    PAUSED_APPLET_EVENT_MAX = PAUSED_APPLET_EVENT_MAX,
})

activeTab = tabState.activeTab
syncAppletWindowVisibility = tabState.syncAppletWindowVisibility
clearUrlSelection = tabState.clearUrlSelection
getUrlSelection = tabState.getUrlSelection
getSelectedUrlText = tabState.getSelectedUrlText
deleteUrlSelection = tabState.deleteUrlSelection
clearPageSelection = tabState.clearPageSelection
bumpRenderRevision = tabState.bumpRenderRevision
pageLineCount = tabState.pageLineCount
normalizedPageSelection = tabState.normalizedPageSelection
pageSelectionContains = tabState.pageSelectionContains
setPageSelection = tabState.setPageSelection
selectAllPageText = tabState.selectAllPageText
getSelectedPageText = tabState.getSelectedPageText
pageHeight = tabState.pageHeight
pageContentWidth = tabState.pageContentWidth
pageOverflowY = tabState.pageOverflowY
maxScroll = tabState.maxScroll
setScroll = tabState.setScroll
canGoBack = tabState.canGoBack
canGoForward = tabState.canGoForward
pushHistory = tabState.pushHistory
collapseExpandedTab = tabState.collapseExpandedTab
toggleExpandedTab = tabState.toggleExpandedTab
activateTab = tabState.activateTab
moveTab = tabState.moveTab
newTab = tabState.newTab
closeTab = tabState.closeTab
closeActiveTab = tabState.closeActiveTab
cycleTabs = tabState.cycleTabs

function runningAppletTitle(tab)
    local applet = tab and tab.applet or nil
    if not applet or not applet.running then
        return nil
    end

    local sourceUrl = trim(tostring(applet.sourceUrl or tab.currentUrl or tab.urlInput or ""))
    if sourceUrl == "" then
        return "Lua Applet"
    end

    local stripped = sourceUrl:gsub("[?#].*$", "")
    local parsed = core.parseUrl and core.parseUrl(stripped) or nil
    local path = parsed and parsed.path or stripped
    local name = trim(tostring((path and path:match("([^/\\]+)$")) or ""))

    if name == "" then
        name = trim(stripped)
    end
    if name == "" then
        return "Lua Applet"
    end
    return name
end

function tabTitle(tab)
    local currentUrl = trim(tab.currentUrl or "")
    local inputUrl = trim(tab.urlInput or "")

    if tab.loading then
        return "Loading..."
    end

    local appletTitle = runningAppletTitle(tab)
    if appletTitle and appletTitle ~= "" then
        return appletTitle
    end

    local title = trim(tab.document and tab.document.title or "")
    if title ~= "" then
        return title
    end

    local url = currentUrl ~= "" and currentUrl or inputUrl
    if url ~= "" then
        return url
    end

    return "New Tab"
end

local ui = createUi({
    state = state,
    clamp = clamp,
    topBarRows = TOP_BAR_ROWS,
    effectiveTopBarRows = effectiveTopBarRows,
    activeTab = activeTab,
    isFavoriteUrl = isFavoriteUrl,
    canFavoriteUrl = canFavoriteUrl,
    canGoBack = canGoBack,
    canGoForward = canGoForward,
    tabTitle = tabTitle,
    getUrlSelection = getUrlSelection,
    normalizedPageSelection = normalizedPageSelection,
    pageSelectionContains = pageSelectionContains,
})

local layoutUi = ui.layoutUi
local tabIndexAt = ui.tabIndexAt
local tabCloseIndexAt = ui.tabCloseIndexAt
local drawBase = ui.draw
local navigate
local scheduleAboutUpdateTimer

function renderDocument(tab)
    local target = tab or activeTab()
    local w, h = term.getSize()
    local visibleHeight = pageHeight()

    local function makeRenderSignature()
        local focusKey = target.focusedFormControl or ""
        return table.concat({
            tostring(target.document),
            tostring(w),
            tostring(h),
            tostring(pageOverflowY(target)),
            tostring(focusKey),
            tostring(target.renderRevision or 0),
        }, "|")
    end

    if not target.document then
        local fallbackBg = currentDefaultBackgroundColorValue()
        local fallbackFg = currentDefaultForegroundColorValue(fallbackBg)
        target.pageLines = { createEmptyLine() }
        target.pageContentHeight = 1
        target.pageWindowStart = 1
        target.pageWindowEnd = 1
        target.pageDefaultBackground = fallbackBg
        target.pageDefaultForeground = fallbackFg
        target.viewportWidth = w
        target.showVerticalScrollbar = false
        target.formMeta = {
            formsById = {},
            formOrder = {},
            formsByHtmlId = {},
            controlsByKey = {},
            controlOrder = {},
            formState = target.formState or {},
        }
        setScroll(0, target)
        target.lastRenderSignature = makeRenderSignature()
        return
    end

    local renderSignature = makeRenderSignature()
    if target.lastRenderSignature == renderSignature then
        return
    end

    local requestedScroll = target.scroll or 0
    local canShowScrollbarColumn = w >= 2
    local overflowY = pageOverflowY(target)
    local forceScrollbar = overflowY == "scroll"
    local allowVerticalScrolling = overflowY ~= "hidden"
    local reserveScrollbar = canShowScrollbarColumn and forceScrollbar
    local contentWidth = math.max(1, w - (reserveScrollbar and 1 or 0))

    local lines = {}
    local formMeta = nil
    local totalLines = 1
    lines, formMeta = renderDocumentLines(
        target.document,
        contentWidth,
        target.formState,
        target.focusedFormControl
    )
    lines = lines or { createEmptyLine() }
    totalLines = math.max(1, #lines)
    if (not reserveScrollbar) and canShowScrollbarColumn and allowVerticalScrolling and totalLines > visibleHeight then
        reserveScrollbar = true
        contentWidth = math.max(1, w - 1)
        lines, formMeta = renderDocumentLines(
            target.document,
            contentWidth,
            target.formState,
            target.focusedFormControl
        )
        lines = lines or { createEmptyLine() }
        totalLines = math.max(1, #lines)
    end

    target.pageContentHeight = totalLines
    target.viewportWidth = contentWidth
    target.showVerticalScrollbar = reserveScrollbar and allowVerticalScrolling
    setScroll(requestedScroll, target)

    target.pageLines = lines
    target.pageContentHeight = totalLines
    target.pageWindowStart = 1
    target.pageWindowEnd = totalLines
    local pageBg = target.document.defaultBackground or currentDefaultBackgroundColorValue()
    local pageFg = target.document.defaultForeground or currentDefaultForegroundColorValue(pageBg)
    target.pageDefaultBackground = pageBg
    target.pageDefaultForeground = pageFg
    target.formMeta = formMeta or {
        formsById = {},
        formOrder = {},
        formsByHtmlId = {},
        controlsByKey = {},
        controlOrder = {},
        formState = target.formState or {},
    }
    target.formState = target.formMeta.formState or target.formState or {}
    if target.focusedFormControl then
        local controls = target.formMeta.controlsByKey or {}
        if not controls[target.focusedFormControl] then
            target.focusedFormControl = nil
        end
    end
    target.lastRenderSignature = makeRenderSignature()
end

function hitRegion(x, y, region)
    if not region then
        return false
    end
    local regionY = region.y or 1
    return y == regionY and x >= region.x1 and x <= region.x2
end

function verticalScrollbarMetrics(tab)
    local target = tab or activeTab()
    local w, _ = term.getSize()
    if not target.showVerticalScrollbar or w < 2 then
        return nil
    end

    local viewportHeight = pageHeight()
    local contentHeight = pageLineCount(target)
    local maxValue = maxScroll(target)
    local thumbHeight = viewportHeight
    if contentHeight > viewportHeight then
        thumbHeight = math.floor((viewportHeight * viewportHeight) / contentHeight + 0.5)
        thumbHeight = clamp(thumbHeight, 1, viewportHeight)
    end

    local travel = viewportHeight - thumbHeight
    local thumbTop = 1
    if maxValue > 0 and travel > 0 then
        local ratio = target.scroll / maxValue
        thumbTop = 1 + math.floor((ratio * travel) + 0.5)
    end

    return {
        x = w,
        y1 = effectiveTopBarRows() + 1,
        y2 = effectiveTopBarRows() + viewportHeight,
        viewportHeight = viewportHeight,
        maxScroll = maxValue,
        thumbTop = thumbTop,
        thumbHeight = thumbHeight,
    }
end

function rerenderAllTabs()
    for _, tab in ipairs(state.tabs) do
        renderDocument(tab)
    end
end

function clearModal()
    state.modal.open = false
    state.modal.spec = nil
    state.modal.layout = nil
end

function openModal(spec)
    if type(spec) ~= "table" then
        return false
    end
    if spec.id ~= "high_usage_guard" then
        state.highUsage.overCount = 0
        state.highUsage.frozen = false
        state.highUsage.loadingFrame = false
        state.highUsage.intentionalUiBreak = true
    end
    state.modal.open = true
    state.modal.spec = spec
    state.modal.layout = nil
    return true
end

function modalButtons(spec)
    local source = (spec and spec.buttons) or {}
    local buttons = {}
    for index, item in ipairs(source) do
        local id = tostring(item.id or index)
        local label = tostring(item.label or ("[" .. id .. "]"))
        local shortLabel = item.shortLabel and tostring(item.shortLabel) or nil
        buttons[#buttons + 1] = {
            id = id,
            label = label,
            shortLabel = shortLabel,
            background = item.background or colors.gray,
            foreground = item.foreground or colors.white,
        }
    end
    if #buttons == 0 then
        buttons[1] = {
            id = "ok",
            label = "[OK]",
            shortLabel = "[OK]",
            background = colors.gray,
            foreground = colors.white,
        }
    end
    return buttons
end

function ensureModalInput(spec)
    if type(spec) ~= "table" then
        return nil
    end
    if type(spec.input) ~= "table" then
        return nil
    end
    spec.input.value = tostring(spec.input.value or "")
    if spec.input.maxLen ~= nil then
        spec.input.maxLen = math.max(1, math.floor(tonumber(spec.input.maxLen) or 256))
    end
    local cursor = tonumber(spec.input.cursor) or (#spec.input.value + 1)
    spec.input.cursor = clamp(math.floor(cursor), 1, #spec.input.value + 1)
    return spec.input
end

function appendModalInput(spec, text)
    local input = ensureModalInput(spec)
    if not input then
        return false
    end
    local chunk = tostring(text or "")
    if chunk == "" then
        return false
    end
    local value = tostring(input.value or "")
    local cursor = clamp(math.floor(tonumber(input.cursor) or (#value + 1)), 1, #value + 1)
    if input.maxLen then
        local remaining = input.maxLen - #value
        if remaining <= 0 then
            return false
        end
        if #chunk > remaining then
            chunk = chunk:sub(1, remaining)
        end
    end
    local before = value:sub(1, cursor - 1)
    local after = value:sub(cursor)
    input.value = before .. chunk .. after
    input.cursor = clamp(cursor + #chunk, 1, #input.value + 1)
    return true
end

function deleteModalInputBack(spec)
    local input = ensureModalInput(spec)
    if not input then
        return false
    end
    local value = tostring(input.value or "")
    local cursor = clamp(math.floor(tonumber(input.cursor) or (#value + 1)), 1, #value + 1)
    if #value <= 0 or cursor <= 1 then
        return false
    end
    local before = value:sub(1, cursor - 2)
    local after = value:sub(cursor)
    input.value = before .. after
    input.cursor = cursor - 1
    return true
end

function deleteModalInputForward(spec)
    local input = ensureModalInput(spec)
    if not input then
        return false
    end
    local value = tostring(input.value or "")
    local cursor = clamp(math.floor(tonumber(input.cursor) or (#value + 1)), 1, #value + 1)
    if #value <= 0 or cursor > #value then
        return false
    end
    local before = value:sub(1, cursor - 1)
    local after = value:sub(cursor + 1)
    input.value = before .. after
    input.cursor = clamp(cursor, 1, #input.value + 1)
    return true
end

function moveModalInputCursor(spec, delta)
    local input = ensureModalInput(spec)
    if not input then
        return false
    end
    local value = tostring(input.value or "")
    local cursor = clamp(math.floor(tonumber(input.cursor) or (#value + 1)), 1, #value + 1)
    local moved = clamp(cursor + math.floor(tonumber(delta) or 0), 1, #value + 1)
    if moved == cursor then
        return false
    end
    input.cursor = moved
    return true
end

function setModalInputCursor(spec, cursorPos)
    local input = ensureModalInput(spec)
    if not input then
        return false
    end
    local value = tostring(input.value or "")
    input.cursor = clamp(parseInteger(cursorPos, (#value + 1)), 1, #value + 1)
    return true
end

function withModalCursorMarker(text, cursor)
    local source = tostring(text or "")
    local cursorPos = clamp(parseInteger(cursor, (#source + 1)), 1, #source + 1)
    return source:sub(1, cursorPos - 1) .. "|" .. source:sub(cursorPos), cursorPos
end

function modalBuildBodyLines(spec)
    local bodyLines = {}
    local sourceLines = spec and spec.lines or nil
    if type(sourceLines) == "table" then
        for _, line in ipairs(sourceLines) do
            bodyLines[#bodyLines + 1] = tostring(line or "")
        end
    end
    if #bodyLines == 0 then
        bodyLines[1] = tostring((spec and spec.message) or "")
    end
    return bodyLines
end

function modalFillRow(x1, panelWidth, y, rowBackground, rowForeground)
    term.setCursorPos(x1, y)
    term.setBackgroundColor(rowBackground)
    term.setTextColor(rowForeground)
    term.write(string.rep(" ", panelWidth))
end

function modalWriteLine(x1, y1, y2, panelWidth, y, text, rowBackground, rowForeground)
    if y < y1 or y > y2 then
        return
    end
    modalFillRow(x1, panelWidth, y, rowBackground, rowForeground)
    local content = tostring(text or "")
    local maxChars = math.max(0, panelWidth - 2)
    if #content > maxChars then
        content = content:sub(1, maxChars)
    end
    term.setCursorPos(x1 + 1, y)
    term.setBackgroundColor(rowBackground)
    term.setTextColor(rowForeground)
    term.write(content)
end

function modalRenderInputLine(x1, y1, y2, panelWidth, inputY, input)
    if not inputY or inputY < y1 or inputY > y2 then
        return
    end

    local inputValue = tostring(input.value or "")
    local placeholder = tostring(input.placeholder or "")
    local shown = inputValue
    if shown == "" then
        shown = placeholder
    end

    local maxChars = math.max(0, panelWidth - 4)
    local displayed = shown
    local cursorPos = clamp(parseInteger(input.cursor, (#inputValue + 1)), 1, #inputValue + 1)
    if #displayed > maxChars then
        local start = 1
        if cursorPos > maxChars then
            start = cursorPos - maxChars + 1
        end
        if start + maxChars - 1 > #displayed then
            start = math.max(1, #displayed - maxChars + 1)
        end
        displayed = displayed:sub(start, start + maxChars - 1)
        cursorPos = clamp(cursorPos - start + 1, 1, #displayed + 1)
    end

    displayed = withModalCursorMarker(displayed, cursorPos)
    local inputBg = colors.white
    local inputFg = (inputValue == "" and placeholder ~= "") and colors.gray or colors.black
    modalWriteLine(x1, y1, y2, panelWidth, inputY, string.rep(" ", math.max(0, panelWidth - 2)), inputBg, inputFg)
    term.setCursorPos(x1 + 1, inputY)
    term.setBackgroundColor(inputBg)
    term.setTextColor(inputFg)
    term.write(displayed)
end

function modalResolveButtonLabels(buttons, panelWidth)
    local labels = {}
    local totalWidth = 0
    for index, button in ipairs(buttons) do
        labels[index] = button.label
        totalWidth = totalWidth + #button.label
    end

    local buttonGap = 2
    totalWidth = totalWidth + (math.max(0, #buttons - 1) * buttonGap)
    local contentWidth = math.max(1, panelWidth - 2)
    if totalWidth > contentWidth then
        totalWidth = 0
        for index, button in ipairs(buttons) do
            local label = button.shortLabel or button.label
            labels[index] = label
            totalWidth = totalWidth + #label
        end
        buttonGap = 1
        totalWidth = totalWidth + (math.max(0, #buttons - 1) * buttonGap)
    end

    return labels, buttonGap, totalWidth
end

function modalDrawButtons(x1, x2, buttonY, buttons, labels, buttonGap, totalWidth)
    local left = x1 + 1
    local right = x2 - 1
    local cursorX = left
    local width = right - left + 1
    if totalWidth < width then
        cursorX = left + math.floor((width - totalWidth) / 2)
    end

    local layoutButtons = {}
    for index, button in ipairs(buttons) do
        local available = right - cursorX + 1
        if available < 1 then
            break
        end

        local label = tostring(labels[index] or "")
        if #label > available then
            label = label:sub(1, available)
        end

        term.setCursorPos(cursorX, buttonY)
        term.setBackgroundColor(button.background)
        term.setTextColor(button.foreground)
        term.write(label)

        layoutButtons[#layoutButtons + 1] = {
            id = button.id,
            x1 = cursorX,
            x2 = cursorX + #label - 1,
            y = buttonY,
        }
        cursorX = cursorX + #label + buttonGap
    end
    return layoutButtons
end

function drawModal()
    local modal = state.modal
    if not modal.open then
        modal.layout = nil
        return false
    end

    local spec = modal.spec
    if type(spec) ~= "table" then
        clearModal()
        return false
    end

    local w, h = term.getSize()
    local bodyLines = modalBuildBodyLines(spec)
    local buttons = modalButtons(spec)
    local input = ensureModalInput(spec)
    local hasInput = input ~= nil
    local hasTitle = trim(tostring(spec.title or "")) ~= ""

    local bodyCount = math.max(1, #bodyLines)
    local panelHeight = math.max(7, bodyCount + (hasTitle and 4 or 3) + (hasInput and 2 or 0))
    panelHeight = math.min(h, panelHeight)
    local panelWidth = math.min(w, math.max(20, math.min(spec.maxWidth or 58, w - 2)))

    local x1 = math.max(1, math.floor((w - panelWidth) / 2) + 1)
    local y1 = math.max(1, math.floor((h - panelHeight) / 2) + 1)
    local x2 = x1 + panelWidth - 1
    local y2 = y1 + panelHeight - 1
    local background = spec.background or colors.lightGray
    local foreground = spec.foreground or colors.black
    local titleBackground = spec.titleBackground or colors.red
    local titleForeground = spec.titleForeground or colors.white

    for y = y1, y2 do
        modalFillRow(x1, panelWidth, y, background, foreground)
    end

    local contentY = y1 + 1
    if hasTitle then
        modalWriteLine(x1, y1, y2, panelWidth, y1, tostring(spec.title), titleBackground, titleForeground)
        contentY = y1 + 2
    end

    local buttonY = math.max(contentY, y2 - 1)
    local inputY = hasInput and (buttonY - 1) or nil
    local maxBodyY = buttonY - (hasInput and 2 or 1)
    for _, line in ipairs(bodyLines) do
        if contentY > maxBodyY then
            break
        end
        modalWriteLine(x1, y1, y2, panelWidth, contentY, line, background, foreground)
        contentY = contentY + 1
    end

    if hasInput and input then
        modalRenderInputLine(x1, y1, y2, panelWidth, inputY, input)
    end

    local labels, buttonGap, totalWidth = modalResolveButtonLabels(buttons, panelWidth)
    local layoutButtons = modalDrawButtons(x1, x2, buttonY, buttons, labels, buttonGap, totalWidth)

    term.setCursorBlink(false)
    modal.layout = {
        panel = { x1 = x1, x2 = x2, y1 = y1, y2 = y2 },
        buttons = layoutButtons,
        input = hasInput and inputY and {
            x1 = x1 + 1,
            x2 = x2 - 1,
            y = inputY,
        } or nil,
    }
    return true
end

function drawActiveAppletOverlay()
    local tab = activeTab()
    local applet = tab and tab.applet or nil
    if not applet or not applet.running or not applet.window then
        return
    end
    syncAppletWindowVisibility()
    if state.menuOpen or state.modal.open then
        return
    end
    if applet.window.setVisible then
        pcall(applet.window.setVisible, true)
    end
    if applet.window.redraw then
        pcall(applet.window.redraw)
    end
end

function showSnackbar(message, durationMs)
    local text = trim(tostring(message or ""))
    if text == "" then
        return
    end
    local snackbar = state.snackbar or {}
    snackbar.active = true
    snackbar.message = text
    snackbar.startedAt = os.clock()
    snackbar.durationMs = math.max(100, math.floor(tonumber(durationMs) or SNACKBAR_DEFAULT_DURATION_MS))
    state.snackbar = snackbar
    state.animationTimer = nil
    if scheduleAnimationTick then
        scheduleAnimationTick()
    end
end

function drawSnackbar()
    local snackbar = state.snackbar
    if not snackbar or not snackbar.active then
        return
    end

    local elapsedMs = (os.clock() - (snackbar.startedAt or 0)) * 1000
    local fadeMs = SNACKBAR_ANIMATION_MS
    local holdMs = math.max(100, tonumber(snackbar.durationMs) or SNACKBAR_DEFAULT_DURATION_MS)
    local totalMs = (fadeMs * 2) + holdMs
    if elapsedMs >= totalMs then
        snackbar.active = false
        return
    end

    local progress = 1
    if elapsedMs < fadeMs then
        progress = elapsedMs / fadeMs
    elseif elapsedMs > (fadeMs + holdMs) then
        progress = (totalMs - elapsedMs) / fadeMs
    end
    progress = clamp(progress, 0, 1)

    local w, h = term.getSize()
    local banner = " " .. tostring(snackbar.message or "") .. " "
    if #banner > SNACKBAR_MAX_WIDTH then
        banner = banner:sub(1, SNACKBAR_MAX_WIDTH - 3) .. ".. "
    end
    if #banner > w then
        banner = banner:sub(1, w)
    end
    if #banner <= 0 then
        return
    end

    local x = math.max(1, math.floor((w - #banner) / 2) + 1)
    local y = h + 2 - math.floor((progress * 2) + 0.5)
    if y < 1 or y > h then
        return
    end

    term.setCursorPos(x, y)
    term.setTextColor(colors.black)
    term.setBackgroundColor(colors.lime)
    term.write(banner)
end

function drawNativeMonitorControls()
    displayManager.drawNativeMonitorControls()
end

function handleNativeMonitorControlClick(button, x, y)
    return displayManager.handleNativeMonitorControlClick(button, x, y)
end

draw = function()
    drawBase()
    drawActiveAppletOverlay()
    drawModal()
    drawSnackbar()
    drawNativeMonitorControls()
end

function triggerModalButton(buttonId, source)
    local modal = state.modal
    if not modal.open then
        return false
    end

    local spec = modal.spec
    if type(spec) ~= "table" then
        clearModal()
        return false
    end

    local shouldClose = spec.autoClose ~= false
    if type(spec.onButton) == "function" then
        local ok, callbackResult = pcall(spec.onButton, buttonId, source, spec)
        if not ok then
            shouldClose = true
        elseif callbackResult == false then
            shouldClose = false
        elseif callbackResult == true then
            shouldClose = true
        end
    end

    if shouldClose and state.modal.open then
        clearModal()
    end
    return true
end

function dismissUsageGuard(continueBrowsing)
    local guard = state.highUsage
    guard.frozen = false
    guard.overCount = 0
    guard.cooldownUntil = os.clock() + HIGH_USAGE_COOLDOWN_SECONDS
    if state.modal.open and state.modal.spec and state.modal.spec.id == "high_usage_guard" then
        clearModal()
    end

    if continueBrowsing then
        renderDocument(activeTab())
        draw()
        return
    end

    closeActiveTab()
    if state.running then
        renderDocument(activeTab())
        draw()
    end
end

function activateUsageGuard(frameMs)
    local guard = state.highUsage
    if not usageGuardEnabled() or guard.frozen then
        return false
    end
    guard.frozen = true
    guard.lastFrameMs = frameMs or 0
    guard.overCount = 0
    local keyActions = {}
    if keys.enter then
        keyActions[keys.enter] = "continue"
    end
    if keys.c then
        keyActions[keys.c] = "continue"
    end
    if keys.escape then
        keyActions[keys.escape] = "close"
    end
    if keys.q then
        keyActions[keys.q] = "close"
    end
    if keys.backspace then
        keyActions[keys.backspace] = "close"
    end
    openModal({
        id = "high_usage_guard",
        title = "High Usage Detected",
        titleBackground = colors.red,
        titleForeground = colors.white,
        lines = {
            "Browser paused to prevent a crash.",
            ("Slow frame: %dms"):format(math.floor((guard.lastFrameMs or 0) + 0.5)),
            "Choose: close tab or continue.",
        },
        buttons = {
            {
                id = "close",
                label = "[Close]",
                shortLabel = "[X]",
                background = colors.red,
                foreground = colors.white,
            },
            {
                id = "continue",
                label = "[Continue]",
                shortLabel = "[Go]",
                background = colors.lime,
                foreground = colors.black,
            },
        },
        keyActions = keyActions,
        autoClose = false,
        onButton = function(buttonId)
            if buttonId == "continue" then
                dismissUsageGuard(true)
            else
                dismissUsageGuard(false)
            end
            return false
        end,
    })
    draw()
    return true
end

function handleModalEvent(event)
    if not state.modal.open then
        return false
    end

    local spec = state.modal.spec or {}
    local name = event[1]
    if name == "timer" then
        if state.animationTimer and event[2] == state.animationTimer then
            state.animationTimer = nil
            scheduleAnimationTick()
        end
        return true
    end

    if name == "term_resize" then
        draw()
        return true
    end

    if name == "key_up" then
        local key = event[2]
        if key == keys.leftCtrl or key == keys.rightCtrl then
            state.ctrlDown = false
        elseif key == keys.leftShift or key == keys.rightShift then
            state.shiftDown = false
        end
        return true
    end

    if name == "key" then
        local key = event[2]
        if key == keys.leftCtrl or key == keys.rightCtrl then
            state.ctrlDown = true
            return true
        end
        if key == keys.leftShift or key == keys.rightShift then
            state.shiftDown = true
            return true
        end

        if ensureModalInput(spec) then
            if key == keys.left then
                moveModalInputCursor(spec, -1)
                draw()
                return true
            end
            if key == keys.right then
                moveModalInputCursor(spec, 1)
                draw()
                return true
            end
            if key == keys.home then
                setModalInputCursor(spec, 1)
                draw()
                return true
            end
            if key == keys["end"] then
                setModalInputCursor(spec, math.huge)
                draw()
                return true
            end
            if key == keys.backspace then
                deleteModalInputBack(spec)
                draw()
                return true
            end
            if key == keys.delete then
                deleteModalInputForward(spec)
                draw()
                return true
            end
        end
        local action = nil
        if type(spec.keyActions) == "table" then
            action = spec.keyActions[key]
        end

        if not action then
            local buttons = modalButtons(spec)
            if key == keys.enter and buttons[1] then
                action = buttons[1].id
            elseif key == keys.escape and buttons[#buttons] then
                action = buttons[#buttons].id
            end
        end

        if action then
            triggerModalButton(action, "key")
        else
            draw()
        end
        return true
    end

    if name == "mouse_click" then
        local x = event[3]
        local y = event[4]
        local layout = state.modal.layout
        if not layout then
            draw()
            layout = state.modal.layout
        end
        if layout and type(layout.buttons) == "table" then
            for _, button in ipairs(layout.buttons) do
                if y == button.y and x >= button.x1 and x <= button.x2 then
                    triggerModalButton(button.id, "mouse")
                    return true
                end
            end
        end
        if layout and layout.input and y == layout.input.y and x >= layout.input.x1 and x <= layout.input.x2 then
            local input = ensureModalInput(spec)
            if input then
                local value = tostring(input.value or "")
                local relative = x - layout.input.x1 + 1
                local cursor = clamp(relative, 1, #value + 1)
                setModalInputCursor(spec, cursor)
            end
            draw()
            return true
        end
        draw()
        return true
    end

    if name == "char" and ensureModalInput(spec) then
        appendModalInput(spec, event[2] or "")
        draw()
        return true
    end

    if name == "paste" and ensureModalInput(spec) then
        appendModalInput(spec, event[2] or "")
        draw()
        return true
    end

    if name == "mouse_drag"
        or name == "mouse_up"
        or name == "mouse_scroll"
        or name == "char"
        or name == "paste" then
        return true
    end

    return false
end

function findFirstTabByUrlPrefix(prefix)
    local wanted = trim(prefix or "")
    if wanted == "" then
        return nil
    end
    for index, tab in ipairs(state.tabs) do
        local current = trim(tab.currentUrl or "")
        if startsWith(current, wanted) then
            return index
        end
    end
    return nil
end

function openOrFocusSettingsTab()
    local existingIndex = findFirstTabByUrlPrefix("about:settings")
    if existingIndex then
        activateTab(existingIndex)
        return
    end

    local tab = newTab("about:settings")
    navigate("about:settings", true, false, tab)
end

