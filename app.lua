local APP_TITLE = "CC Browser"
local APP_VERSION = "0.1.0"
local APP_ICON = "[CC]"

local function getScriptDir()
    if shell and shell.getRunningProgram and fs and fs.getDir then
        local running = shell.getRunningProgram()
        if running and running ~= "" then
            return fs.getDir(running)
        end
    end
    return "/src/browser"
end

local SCRIPT_DIR = getScriptDir()

local function loadModule(relativePath)
    return dofile(fs.combine(SCRIPT_DIR, relativePath))
end

local core = loadModule("lib/core.lua")
local createNetwork = loadModule("lib/network.lua")
local createHtml = loadModule("lib/html.lua")
local createContent = loadModule("lib/content.lua")
local createUi = loadModule("ui/view.lua")

local browserSettings = {
    home_page = "about:home",
    turtle_mode = "false",
    history_enabled = "true",
    persistence_enabled = "true",
    usage_guard_enabled = "true",
}
local browserFavorites = {}
local browserHistory = {}
local nextBrowserHistoryId = 1
local BROWSER_STATE_PATH = fs.combine(SCRIPT_DIR, "browser-state.tbl")
local persistBrowserState

local function settingEnabledRaw(name, defaultEnabled)
    local defaultText = defaultEnabled and "true" or "false"
    local raw = core.trim(tostring(browserSettings[name] or defaultText)):lower()
    return not (raw == "false" or raw == "0" or raw == "no" or raw == "off" or raw == "disabled")
end

local function normalizeSettingKey(key)
    local normalized = tostring(key or ""):lower()
    normalized = normalized:gsub("[^%w_%-]", "_")
    normalized = normalized:gsub("_+", "_")
    if normalized == "virtual_views" then
        normalized = "turtle_mode"
    end
    return normalized
end

local function listBrowserSettings()
    local copied = {}
    for key, value in pairs(browserSettings) do
        copied[key] = tostring(value)
    end
    return copied
end

local function getBrowserSetting(key)
    local normalized = normalizeSettingKey(key)
    if normalized == "" then
        return nil
    end
    return browserSettings[normalized]
end

local function setBrowserSetting(key, value)
    local normalized = normalizeSettingKey(key)
    if normalized == "" then
        return false, "Invalid setting key"
    end
    if value == nil then
        return false, "Missing setting value"
    end
    if normalized == "turtle_mode" then
        local lowered = core.trim(tostring(value)):lower()
        if lowered == "true" or lowered == "1" or lowered == "yes" or lowered == "on" or lowered == "enabled" then
            browserSettings[normalized] = "true"
            browserSettings.usage_guard_enabled = "false"
            if persistBrowserState then
                persistBrowserState()
            end
            return true, nil
        end
        if lowered == "false" or lowered == "0" or lowered == "no" or lowered == "off" or lowered == "disabled" then
            browserSettings[normalized] = "false"
            if persistBrowserState then
                persistBrowserState()
            end
            return true, nil
        end
        return false, "Invalid turtle_mode value (expected true/false)"
    end
    if normalized == "history_enabled" then
        local lowered = core.trim(tostring(value)):lower()
        if lowered == "true" or lowered == "1" or lowered == "yes" or lowered == "on" or lowered == "enabled" then
            browserSettings[normalized] = "true"
            if persistBrowserState then
                persistBrowserState()
            end
            return true, nil
        end
        if lowered == "false" or lowered == "0" or lowered == "no" or lowered == "off" or lowered == "disabled" then
            browserSettings[normalized] = "false"
            if persistBrowserState then
                persistBrowserState()
            end
            return true, nil
        end
        return false, "Invalid history_enabled value (expected true/false)"
    end
    if normalized == "persistence_enabled" then
        local lowered = core.trim(tostring(value)):lower()
        if lowered == "true" or lowered == "1" or lowered == "yes" or lowered == "on" or lowered == "enabled" then
            browserSettings[normalized] = "true"
            if persistBrowserState then
                persistBrowserState(true)
            end
            return true, nil
        end
        if lowered == "false" or lowered == "0" or lowered == "no" or lowered == "off" or lowered == "disabled" then
            browserSettings[normalized] = "false"
            if persistBrowserState then
                persistBrowserState(true)
            end
            return true, nil
        end
        return false, "Invalid persistence_enabled value (expected true/false)"
    end
    if normalized == "usage_guard_enabled" then
        local lowered = core.trim(tostring(value)):lower()
        if lowered == "true" or lowered == "1" or lowered == "yes" or lowered == "on" or lowered == "enabled" then
            if settingEnabledRaw("turtle_mode", false) then
                browserSettings[normalized] = "false"
                return false, "usage_guard_enabled cannot be enabled while turtle_mode is enabled"
            end
            browserSettings[normalized] = "true"
            if persistBrowserState then
                persistBrowserState()
            end
            return true, nil
        end
        if lowered == "false" or lowered == "0" or lowered == "no" or lowered == "off" or lowered == "disabled" then
            browserSettings[normalized] = "false"
            if persistBrowserState then
                persistBrowserState()
            end
            return true, nil
        end
        return false, "Invalid usage_guard_enabled value (expected true/false)"
    end
    browserSettings[normalized] = tostring(value)
    if persistBrowserState then
        persistBrowserState()
    end
    return true, nil
end

local function listBrowserFavorites()
    local copied = {}
    for i, item in ipairs(browserFavorites) do
        copied[i] = {
            url = tostring(item.url or ""),
            title = tostring(item.title or ""),
        }
    end
    return copied
end

local function addBrowserFavorite(url, title)
    local rawUrl = core.trim(tostring(url or ""))
    if rawUrl == "" then
        return false, "Missing favorite URL"
    end
    if core.startsWith(rawUrl:lower(), "about:") then
        return false, "Cannot favorite about pages"
    end

    local normalizedUrl = rawUrl
    if type(core.normalizeInputUrl) == "function" then
        local normalized = core.normalizeInputUrl(rawUrl)
        if type(normalized) == "table" then
            normalized = normalized[1]
        end
        if type(normalized) == "string" and normalized ~= "" then
            normalizedUrl = core.trim(normalized)
        end
    end

    for _, existing in ipairs(browserFavorites) do
        if tostring(existing.url or "") == normalizedUrl then
            return false, "Already in favorites"
        end
    end

    local favoriteTitle = core.trim(tostring(title or ""))
    if favoriteTitle == "" then
        favoriteTitle = normalizedUrl
    end

    browserFavorites[#browserFavorites + 1] = {
        url = normalizedUrl,
        title = favoriteTitle,
    }
    if persistBrowserState then
        persistBrowserState()
    end
    return true, nil
end

local function normalizeFavoriteUrl(url)
    local rawUrl = core.trim(tostring(url or ""))
    if rawUrl == "" then
        return ""
    end
    local normalizedUrl = rawUrl
    if type(core.normalizeInputUrl) == "function" then
        local normalized = core.normalizeInputUrl(rawUrl)
        if type(normalized) == "table" then
            normalized = normalized[1]
        end
        if type(normalized) == "string" and normalized ~= "" then
            normalizedUrl = core.trim(normalized)
        end
    end
    return normalizedUrl
end

local function findFavoriteIndex(url)
    local normalizedUrl = normalizeFavoriteUrl(url)
    if normalizedUrl == "" then
        return nil, ""
    end
    for index, existing in ipairs(browserFavorites) do
        if tostring(existing.url or "") == normalizedUrl then
            return index, normalizedUrl
        end
    end
    return nil, normalizedUrl
end

local function isFavoriteUrl(url)
    local index = findFavoriteIndex(url)
    return index ~= nil
end

local function canFavoriteUrl(url)
    local normalizedUrl = normalizeFavoriteUrl(url)
    if normalizedUrl == "" then
        return false
    end
    return not core.startsWith(normalizedUrl:lower(), "about:")
end

local function removeBrowserFavorite(url)
    local index = findFavoriteIndex(url)
    if not index then
        return false, "Not in favorites"
    end
    table.remove(browserFavorites, index)
    if persistBrowserState then
        persistBrowserState()
    end
    return true, nil
end

local function historyTimestampParts()
    if os and type(os.date) == "function" then
        local okDate, dayText = pcall(os.date, "%Y-%m-%d")
        local okDateTime, dateTimeText = pcall(os.date, "%Y-%m-%d %H:%M:%S")
        if okDate and okDateTime and dayText and dateTimeText then
            return tostring(dayText), tostring(dateTimeText)
        end
    end
    local fallback = ("clock %.2fs"):format((os and type(os.clock) == "function") and os.clock() or 0)
    return "Unknown", fallback
end

local function copyBrowserHistoryEntry(entry)
    return {
        id = tonumber(entry.id) or 0,
        url = tostring(entry.url or ""),
        title = tostring(entry.title or ""),
        day = tostring(entry.day or "Unknown"),
        timestamp = tostring(entry.timestamp or ""),
    }
end

local function listBrowserHistory()
    local copied = {}
    for i, entry in ipairs(browserHistory) do
        copied[i] = copyBrowserHistoryEntry(entry)
    end
    return copied
end

local function removeBrowserHistoryEntry(entryId)
    local wanted = tonumber(entryId)
    if not wanted then
        return false, "Missing history entry id"
    end
    wanted = math.max(1, math.floor(wanted))

    for i, entry in ipairs(browserHistory) do
        if tonumber(entry.id) == wanted then
            table.remove(browserHistory, i)
            if persistBrowserState then
                persistBrowserState()
            end
            return true, nil
        end
    end
    return false, "History entry not found"
end

local function clearBrowserHistoryDay(day)
    local wanted = core.trim(tostring(day or ""))
    if wanted == "" then
        return false, "Missing history day"
    end

    local kept = {}
    local removed = 0
    for _, entry in ipairs(browserHistory) do
        if tostring(entry.day or "") == wanted then
            removed = removed + 1
        else
            kept[#kept + 1] = entry
        end
    end

    if removed <= 0 then
        return false, "History day not found"
    end

    browserHistory = kept
    if persistBrowserState then
        persistBrowserState()
    end
    return true, nil
end

local function clearBrowserHistory()
    browserHistory = {}
    if persistBrowserState then
        persistBrowserState()
    end
    return true, nil
end

local function shouldTrackNavigationInHistory(rawUrl)
    local normalizedUrl = core.trim(tostring(rawUrl or "")):lower()
    if normalizedUrl == "" then
        return false
    end
    if core.startsWith(normalizedUrl, "about:history?action=") then
        return false
    end
    if core.startsWith(normalizedUrl, "about:settings?action=set") then
        return false
    end
    return true
end

local function addBrowserHistory(url, title)
    if not settingEnabledRaw("history_enabled", true) then
        return false
    end

    local normalizedUrl = core.trim(tostring(url or ""))
    if normalizedUrl == "" then
        return false
    end
    local lowerUrl = normalizedUrl:lower()
    if core.startsWith(lowerUrl, "about:history")
        and lowerUrl:find("?action=", 1, true) then
        return false
    end

    local day, timestamp = historyTimestampParts()
    local normalizedTitle = core.trim(tostring(title or ""))
    browserHistory[#browserHistory + 1] = {
        id = nextBrowserHistoryId,
        url = normalizedUrl,
        title = normalizedTitle,
        day = day,
        timestamp = timestamp,
    }
    nextBrowserHistoryId = nextBrowserHistoryId + 1

    if persistBrowserState then
        persistBrowserState()
    end
    return true
end

local function loadBrowserState()
    if not (fs and fs.exists and fs.open) then
        return false, "Filesystem unavailable"
    end
    if not (textutils and type(textutils.unserialize) == "function") then
        return false, "Serializer unavailable"
    end
    if not fs.exists(BROWSER_STATE_PATH) then
        return false, "No saved state"
    end

    local handle = fs.open(BROWSER_STATE_PATH, "r")
    if not handle then
        return false, "Could not open saved state"
    end
    local payload = handle.readAll() or ""
    handle.close()
    if payload == "" then
        return false, "Saved state is empty"
    end

    local okParse, decoded = pcall(textutils.unserialize, payload)
    if not okParse or type(decoded) ~= "table" then
        return false, "Saved state is invalid"
    end

    if type(decoded.settings) == "table" then
        for key, rawValue in pairs(decoded.settings) do
            local normalized = normalizeSettingKey(key)
            if normalized ~= "" then
                browserSettings[normalized] = tostring(rawValue)
            end
        end
    end

    browserFavorites = {}
    if type(decoded.favorites) == "table" then
        for _, item in ipairs(decoded.favorites) do
            local url = core.trim(tostring(item and item.url or ""))
            if url ~= "" then
                local title = core.trim(tostring(item and item.title or ""))
                if title == "" then
                    title = url
                end
                browserFavorites[#browserFavorites + 1] = {
                    url = url,
                    title = title,
                }
            end
        end
    end

    browserHistory = {}
    local maxId = 0
    if type(decoded.history) == "table" then
        for _, item in ipairs(decoded.history) do
            local url = core.trim(tostring(item and item.url or ""))
            if url ~= "" then
                local id = tonumber(item.id)
                if not id then
                    id = maxId + 1
                else
                    id = math.max(1, math.floor(id))
                end
                if id <= maxId then
                    id = maxId + 1
                end
                maxId = id

                local title = core.trim(tostring(item.title or ""))
                local day = core.trim(tostring(item.day or ""))
                local timestamp = core.trim(tostring(item.timestamp or ""))
                if day == "" then
                    day = "Unknown"
                end
                if timestamp == "" then
                    timestamp = day
                end

                browserHistory[#browserHistory + 1] = {
                    id = id,
                    url = url,
                    title = title,
                    day = day,
                    timestamp = timestamp,
                }
            end
        end
    end
    nextBrowserHistoryId = math.max(maxId + 1, 1)

    if settingEnabledRaw("turtle_mode", false) then
        browserSettings.usage_guard_enabled = "false"
    end
    return true, nil
end

persistBrowserState = function(forceWrite)
    if (not forceWrite) and not settingEnabledRaw("persistence_enabled", true) then
        return false, "Persistence disabled"
    end
    if not (fs and fs.open) then
        return false, "Filesystem unavailable"
    end
    if not (textutils and type(textutils.serialize) == "function") then
        return false, "Serializer unavailable"
    end

    local snapshot = {
        version = 1,
        settings = listBrowserSettings(),
        favorites = listBrowserFavorites(),
        history = listBrowserHistory(),
    }
    local encoded = textutils.serialize(snapshot)
    if not encoded then
        return false, "Failed to encode state"
    end

    local handle = fs.open(BROWSER_STATE_PATH, "w")
    if not handle then
        return false, "Could not open state file for writing"
    end
    handle.write(encoded)
    handle.close()
    return true, nil
end

loadBrowserState()

local network = createNetwork(core, {
    aboutPagesDir = fs.combine(SCRIPT_DIR, "about-pages"),
    aboutApi = {
        appTitle = APP_TITLE,
        appVersion = APP_VERSION,
        appIcon = APP_ICON,
        listSettings = listBrowserSettings,
        getSetting = getBrowserSetting,
        setSetting = setBrowserSetting,
        listFavorites = listBrowserFavorites,
        listHistory = listBrowserHistory,
        removeHistoryEntry = removeBrowserHistoryEntry,
        clearHistoryDay = clearBrowserHistoryDay,
        clearHistory = clearBrowserHistory,
    },
})
local html = createHtml(core)
local content = createContent({
    core = core,
    html = html,
    network = network,
})

local clamp = core.clamp
local startsWith = core.startsWith
local trim = core.trim
local escapeHtml = core.escapeHtml
local normalizeInputUrl = core.normalizeInputUrl
local getHeader = core.getHeader

local function homePageUrl()
    local homePage = trim(browserSettings.home_page or "about:home")
    if homePage == "" then
        homePage = "about:home"
    end
    return homePage
end

local function turtleModeEnabled()
    return settingEnabledRaw("turtle_mode", false)
end

local function usageGuardEnabled()
    if turtleModeEnabled() then
        return false
    end
    return settingEnabledRaw("usage_guard_enabled", true)
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
local ANIMATION_TICK_SECONDS = 0.15
local HIGH_USAGE_FRAME_THRESHOLD_MS = 750
local HIGH_USAGE_FRAME_THRESHOLD_LOADING_MS = 10000
local HIGH_USAGE_STRIKE_LIMIT = 1
local HIGH_USAGE_COOLDOWN_SECONDS = 2.0
local ABOUT_UPDATE_INTERVAL_HEADER = "X-CC-About-Update-Ms"
local SETTINGS_STATUS_HEADER = "X-CC-Settings-Status"
local scheduleAnimationTick

local function parseAboutUpdateIntervalMs(headers)
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

local function parseSettingsStatusMessage(headers, currentUrl)
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

local function createTab(initialUrl)
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
        renderRevision = 0,
        lastRenderSignature = nil,
        viewportWidth = 1,
        showVerticalScrollbar = false,
        pageSelection = nil,
        formState = {},
        formMeta = nil,
        focusedFormControl = nil,
        loading = false,
        status = "",
        aboutUpdateIntervalMs = nil,
        settingsStickyStatus = nil,
    }
end

local state = {
    tabs = { createTab(homePageUrl()) },
    activeTab = 1,
    menuOpen = false,
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
    aboutUpdate = {
        timer = nil,
        tabIndex = nil,
        intervalMs = nil,
    },
    running = true,
    ctrlDown = false,
    shiftDown = false,
    highUsage = {
        frozen = false,
        overCount = 0,
        lastFrameMs = 0,
        cooldownUntil = 0,
        loadingFrame = false,
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
}

local function activeTab()
    if #state.tabs < 1 then
        state.tabs[1] = createTab(homePageUrl())
        state.activeTab = 1
    end
    state.activeTab = clamp(state.activeTab, 1, #state.tabs)
    return state.tabs[state.activeTab]
end

local function clearUrlSelection(tab)
    local target = tab or activeTab()
    target.urlSelStart = nil
    target.urlSelEnd = nil
end

local function getUrlSelection(tab)
    local target = tab or activeTab()
    if target.urlSelStart == nil or target.urlSelEnd == nil then
        return nil, nil
    end

    local maxPos = #target.urlInput + 1
    local startPos = clamp(target.urlSelStart, 1, maxPos)
    local endPos = clamp(target.urlSelEnd, 1, maxPos)
    if startPos > endPos then
        startPos, endPos = endPos, startPos
    end
    if startPos == endPos then
        return nil, nil
    end
    return startPos, endPos
end

local function getSelectedUrlText(tab)
    local target = tab or activeTab()
    local startPos, endPos = getUrlSelection(target)
    if not startPos then
        return ""
    end
    return target.urlInput:sub(startPos, endPos - 1)
end

local function deleteUrlSelection(tab)
    local target = tab or activeTab()
    local startPos, endPos = getUrlSelection(target)
    if not startPos then
        return false
    end

    local before = target.urlInput:sub(1, startPos - 1)
    local after = target.urlInput:sub(endPos)
    target.urlInput = before .. after
    target.urlCursor = startPos
    clearUrlSelection(target)
    return true
end

local function clearPageSelection(tab)
    local target = tab or activeTab()
    target.pageSelection = nil
end

local function bumpRenderRevision(tab)
    local target = tab or activeTab()
    target.renderRevision = (target.renderRevision or 0) + 1
end

local function pageLineCount(tab)
    local target = tab or activeTab()
    local count = tonumber(target.pageContentHeight)
    if not count then
        count = #target.pageLines
    end
    return math.max(1, math.floor(count or 1))
end

local function normalizedPageSelection(tab)
    local target = tab or activeTab()
    local selection = target.pageSelection
    if not selection then
        return nil
    end

    local startLine = selection.startLine or 1
    local startCol = selection.startCol or 1
    local endLine = selection.endLine or startLine
    local endCol = selection.endCol or startCol

    if (startLine > endLine) or (startLine == endLine and startCol > endCol) then
        startLine, endLine = endLine, startLine
        startCol, endCol = endCol, startCol
    end

    return {
        startLine = startLine,
        startCol = startCol,
        endLine = endLine,
        endCol = endCol,
    }
end

local function pageSelectionContains(selection, lineIndex, column)
    if not selection then
        return false
    end
    if lineIndex < selection.startLine or lineIndex > selection.endLine then
        return false
    end
    if lineIndex == selection.startLine and column < selection.startCol then
        return false
    end
    if lineIndex == selection.endLine and column > selection.endCol then
        return false
    end
    return true
end

local function setPageSelection(tab, startLine, startCol, endLine, endCol)
    local target = tab or activeTab()
    local w = math.max(1, target.viewportWidth or 1)
    local maxLine = pageLineCount(target)

    target.pageSelection = {
        startLine = clamp(startLine, 1, maxLine),
        startCol = clamp(startCol, 1, w),
        endLine = clamp(endLine, 1, maxLine),
        endCol = clamp(endCol, 1, w),
    }
end

local function selectAllPageText(tab)
    local target = tab or activeTab()
    local totalLines = pageLineCount(target)
    if totalLines < 1 then
        clearPageSelection(target)
        return
    end

    local width = math.max(1, target.viewportWidth or 1)
    setPageSelection(target, 1, 1, totalLines, width)
end

local function getSelectedPageText(tab)
    local target = tab or activeTab()
    local selection = normalizedPageSelection(target)
    if not selection then
        return ""
    end

    local w = math.max(1, target.viewportWidth or 1)
    local sourceLines = target.pageLines or {}
    local missingRange = false
    for lineIndex = selection.startLine, selection.endLine do
        if sourceLines[lineIndex] == nil then
            missingRange = true
            break
        end
    end
    if missingRange and target.document then
        local requestedCount = selection.endLine - selection.startLine + 1
        local windowLines = select(
            1,
            renderDocumentWindowLines(
                target.document,
                w,
                selection.startLine,
                requestedCount,
                target.formState,
                target.focusedFormControl
            )
        )
        if type(windowLines) == "table" then
            sourceLines = windowLines
        end
    end

    local parts = {}
    for lineIndex = selection.startLine, selection.endLine do
        local startCol = (lineIndex == selection.startLine) and selection.startCol or 1
        local endCol = (lineIndex == selection.endLine) and selection.endCol or w
        startCol = clamp(startCol, 1, w)
        endCol = clamp(endCol, 1, w)
        if endCol < startCol then
            startCol, endCol = endCol, startCol
        end

        local line = sourceLines[lineIndex] or target.pageLines[lineIndex]
        local chars = {}
        for x = startCol, endCol do
            chars[#chars + 1] = (line and line.chars and line.chars[x]) or " "
        end
        parts[#parts + 1] = table.concat(chars):gsub("%s+$", "")
    end

    return table.concat(parts, "\n")
end

local function pageHeight()
    local _, h = term.getSize()
    return math.max(1, h - TOP_BAR_ROWS)
end

local function pageContentWidth(tab)
    local target = tab or activeTab()
    local w, _ = term.getSize()
    return clamp(target.viewportWidth or w, 1, w)
end

local function pageOverflowY(tab)
    local target = tab or activeTab()
    local mode = target and target.document and target.document.pageOverflowY or "visible"
    if mode == "hidden" or mode == "scroll" or mode == "auto" then
        return mode
    end
    return "visible"
end

local function maxScroll(tab)
    local target = tab or activeTab()
    if pageOverflowY(target) == "hidden" then
        return 0
    end
    return math.max(0, pageLineCount(target) - pageHeight())
end

local function setScroll(value, tab)
    local target = tab or activeTab()
    target.scroll = clamp(value, 0, maxScroll(target))
end

local function canGoBack(tab)
    local target = tab or activeTab()
    return target.historyIndex > 1
end

local function canGoForward(tab)
    local target = tab or activeTab()
    return target.historyIndex > 0 and target.historyIndex < #target.history
end

local function pushHistory(tab, url)
    local target = tab or activeTab()
    for i = #target.history, target.historyIndex + 1, -1 do
        target.history[i] = nil
    end
    table.insert(target.history, url)
    target.historyIndex = #target.history
end

local function collapseExpandedTab()
    state.expandedTabIndex = nil
end

local function toggleExpandedTab(index)
    if state.expandedTabIndex == index then
        collapseExpandedTab()
    else
        state.expandedTabIndex = index
    end
end

local function activateTab(index)
    if #state.tabs < 1 then
        return
    end
    state.menuOpen = false
    state.activeTab = clamp(index, 1, #state.tabs)
    state.tabDrag = nil
    state.scrollbarDrag = nil
    if state.expandedTabIndex and state.expandedTabIndex ~= state.activeTab then
        collapseExpandedTab()
    end
end

local function moveTab(fromIndex, toIndex)
    if fromIndex == toIndex then
        return
    end
    if fromIndex < 1 or fromIndex > #state.tabs then
        return
    end
    if toIndex < 1 or toIndex > #state.tabs then
        return
    end

    local moved = table.remove(state.tabs, fromIndex)
    table.insert(state.tabs, toIndex, moved)

    if state.activeTab == fromIndex then
        state.activeTab = toIndex
    elseif fromIndex < state.activeTab and toIndex >= state.activeTab then
        state.activeTab = state.activeTab - 1
    elseif fromIndex > state.activeTab and toIndex <= state.activeTab then
        state.activeTab = state.activeTab + 1
    end

    local expanded = state.expandedTabIndex
    if expanded then
        if expanded == fromIndex then
            state.expandedTabIndex = toIndex
        elseif fromIndex < expanded and toIndex >= expanded then
            state.expandedTabIndex = expanded - 1
        elseif fromIndex > expanded and toIndex <= expanded then
            state.expandedTabIndex = expanded + 1
        end
    end
end

local function newTab(initialUrl)
    local tab = createTab(initialUrl or homePageUrl())
    table.insert(state.tabs, tab)
    collapseExpandedTab()
    activateTab(#state.tabs)
    return tab
end

local function closeTab(index)
    local targetIndex = clamp(index or state.activeTab, 1, #state.tabs)
    if #state.tabs <= 1 then
        local tab = activeTab()
        tab.currentUrl = "about:blank"
        tab.urlInput = "about:blank"
        tab.urlCursor = #tab.urlInput + 1
        tab.urlOffset = 0
        clearUrlSelection(tab)
        tab.urlFocus = false
        tab.scroll = 0
        tab.history = { "about:blank" }
        tab.historyIndex = 1
        tab.document = buildDocument("<html><body></body></html>", "about:blank")
        tab.pageLines = { createEmptyLine() }
        tab.pageContentHeight = 1
        tab.pageWindowStart = 1
        tab.pageWindowEnd = 1
        tab.renderRevision = 0
        tab.lastRenderSignature = nil
        tab.viewportWidth = 1
        tab.showVerticalScrollbar = false
        clearPageSelection(tab)
        tab.formState = {}
        tab.formMeta = nil
        tab.focusedFormControl = nil
        tab.loading = false
        tab.status = ""
        tab.aboutUpdateIntervalMs = nil
        state.tabDrag = nil
        state.scrollbarDrag = nil
        state.menuOpen = false
        collapseExpandedTab()
        return
    end

    table.remove(state.tabs, targetIndex)
    if targetIndex < state.activeTab then
        state.activeTab = state.activeTab - 1
    elseif targetIndex == state.activeTab and state.activeTab > #state.tabs then
        state.activeTab = #state.tabs
    end
    state.activeTab = clamp(state.activeTab, 1, #state.tabs)
    state.tabDrag = nil
    state.scrollbarDrag = nil
    state.menuOpen = false

    local expanded = state.expandedTabIndex
    if expanded then
        if targetIndex == expanded then
            collapseExpandedTab()
        elseif targetIndex < expanded then
            state.expandedTabIndex = expanded - 1
        end
    end
end

local function closeActiveTab()
    closeTab(state.activeTab)
end

local function cycleTabs(direction)
    if #state.tabs <= 1 then
        return
    end
    local index = state.activeTab + direction
    if index < 1 then
        index = #state.tabs
    elseif index > #state.tabs then
        index = 1
    end
    activateTab(index)
end

local function tabTitle(tab)
    local currentUrl = trim(tab.currentUrl or "")
    local inputUrl = trim(tab.urlInput or "")

    if tab.loading then
        return "Loading..."
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
local draw
local navigate
local scheduleAboutUpdateTimer

local function renderDocument(tab)
    local target = tab or activeTab()
    local turtleMode = turtleModeEnabled()
    local w, h = term.getSize()
    local visibleHeight = pageHeight()

    local function makeRenderSignature()
        local focusKey = target.focusedFormControl or ""
        return table.concat({
            tostring(target.document),
            turtleMode and "turtle" or "full",
            tostring(w),
            tostring(h),
            tostring(pageOverflowY(target)),
            tostring(focusKey),
            tostring(target.renderRevision or 0),
        }, "|")
    end

    if not target.document then
        target.pageLines = { createEmptyLine() }
        target.pageContentHeight = 1
        target.pageWindowStart = 1
        target.pageWindowEnd = 1
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

    local viewportStart = math.max(1, (target.scroll or 0) + 1)
    local viewportEnd = viewportStart + visibleHeight - 1
    local renderSignature = makeRenderSignature()
    if target.lastRenderSignature == renderSignature then
        if turtleMode then
            local windowStart = tonumber(target.pageWindowStart) or 1
            local windowEnd = tonumber(target.pageWindowEnd) or 0
            if viewportStart >= windowStart and viewportEnd <= windowEnd then
                return
            end
        else
            return
        end
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
    local windowStart = 1
    local windowEnd = 1

    if turtleMode then
        local overscan = math.max(2, math.floor(visibleHeight / 3))
        local windowLineCount = visibleHeight + (overscan * 2)

        local function renderWindowAt(widthValue, startLine)
            local linesOut, metaOut, totalOut = renderDocumentWindowLines(
                target.document,
                widthValue,
                startLine,
                windowLineCount,
                target.formState,
                target.focusedFormControl
            )
            totalOut = math.max(1, tonumber(totalOut) or (#linesOut or 0))
            return linesOut or {}, metaOut, totalOut
        end

        windowStart = math.max(1, requestedScroll + 1 - overscan)
        lines, formMeta, totalLines = renderWindowAt(contentWidth, windowStart)
        if (not reserveScrollbar) and canShowScrollbarColumn and allowVerticalScrolling and totalLines > visibleHeight then
            reserveScrollbar = true
            contentWidth = math.max(1, w - 1)
            lines, formMeta, totalLines = renderWindowAt(contentWidth, windowStart)
        end

        target.pageContentHeight = totalLines
        target.viewportWidth = contentWidth
        target.showVerticalScrollbar = reserveScrollbar and allowVerticalScrolling
        setScroll(requestedScroll, target)

        if target.scroll ~= requestedScroll then
            windowStart = math.max(1, target.scroll + 1 - overscan)
            lines, formMeta, totalLines = renderWindowAt(contentWidth, windowStart)
        end

        windowEnd = windowStart + windowLineCount - 1
    else
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
        windowStart = 1
        windowEnd = totalLines
    end

    target.pageLines = lines
    target.pageContentHeight = totalLines
    target.pageWindowStart = windowStart
    target.pageWindowEnd = windowEnd
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

local function hitRegion(x, y, region)
    if not region then
        return false
    end
    local regionY = region.y or 1
    return y == regionY and x >= region.x1 and x <= region.x2
end

local function verticalScrollbarMetrics(tab)
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
        y1 = TOP_BAR_ROWS + 1,
        y2 = TOP_BAR_ROWS + viewportHeight,
        viewportHeight = viewportHeight,
        maxScroll = maxValue,
        thumbTop = thumbTop,
        thumbHeight = thumbHeight,
    }
end

local function rerenderAllTabs()
    for _, tab in ipairs(state.tabs) do
        renderDocument(tab)
    end
end

local function clearModal()
    state.modal.open = false
    state.modal.spec = nil
    state.modal.layout = nil
end

local function openModal(spec)
    if type(spec) ~= "table" then
        return false
    end
    state.modal.open = true
    state.modal.spec = spec
    state.modal.layout = nil
    return true
end

local function modalButtons(spec)
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

local function drawModal()
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
    local bodyLines = {}
    local sourceLines = spec.lines
    if type(sourceLines) == "table" then
        for _, line in ipairs(sourceLines) do
            bodyLines[#bodyLines + 1] = tostring(line or "")
        end
    end
    if #bodyLines == 0 then
        bodyLines[1] = tostring(spec.message or "")
    end

    local buttons = modalButtons(spec)
    local hasTitle = trim(tostring(spec.title or "")) ~= ""
    local bodyCount = math.max(1, #bodyLines)
    local panelHeight = math.max(7, bodyCount + (hasTitle and 4 or 3))
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

    local function fillRow(y, rowBackground, rowForeground)
        term.setCursorPos(x1, y)
        term.setBackgroundColor(rowBackground)
        term.setTextColor(rowForeground)
        term.write(string.rep(" ", panelWidth))
    end

    local function writeLine(y, text, rowBackground, rowForeground)
        if y < y1 or y > y2 then
            return
        end
        fillRow(y, rowBackground, rowForeground)
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

    for y = y1, y2 do
        fillRow(y, background, foreground)
    end

    local contentY = y1 + 1
    if hasTitle then
        writeLine(y1, tostring(spec.title), titleBackground, titleForeground)
        contentY = y1 + 2
    end

    local buttonY = math.max(contentY, y2 - 1)
    local maxBodyY = buttonY - 1
    for _, line in ipairs(bodyLines) do
        if contentY > maxBodyY then
            break
        end
        writeLine(contentY, line, background, foreground)
        contentY = contentY + 1
    end

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

    local left = x1 + 1
    local right = x2 - 1
    local cursorX = left
    if totalWidth < (right - left + 1) then
        cursorX = left + math.floor(((right - left + 1) - totalWidth) / 2)
    end

    local layoutButtons = {}
    for index, button in ipairs(buttons) do
        local available = right - cursorX + 1
        if available < 1 then
            break
        end

        local label = labels[index]
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

    term.setCursorBlink(false)
    modal.layout = {
        panel = { x1 = x1, x2 = x2, y1 = y1, y2 = y2 },
        buttons = layoutButtons,
    }
    return true
end

draw = function()
    drawBase()
    drawModal()
end

local function triggerModalButton(buttonId, source)
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

local function dismissUsageGuard(continueBrowsing)
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

local function activateUsageGuard(frameMs)
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

local function handleModalEvent(event)
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

    if name == "key" then
        local key = event[2]
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
        draw()
        return true
    end

    if name == "mouse_drag"
        or name == "mouse_up"
        or name == "mouse_scroll"
        or name == "char"
        or name == "paste"
        or name == "key_up" then
        return true
    end

    return false
end

local function findFirstTabByUrlPrefix(prefix)
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

local function openOrFocusSettingsTab()
    local existingIndex = findFirstTabByUrlPrefix("about:settings")
    if existingIndex then
        activateTab(existingIndex)
        return
    end

    local tab = newTab("about:settings")
    navigate("about:settings", true, false, tab)
end

local function openHelpTab()
    local existingIndex = findFirstTabByUrlPrefix("about:help")
    if existingIndex then
        activateTab(existingIndex)
        return
    end

    local tab = newTab("about:help")
    navigate("about:help", true, false, tab)
end

local function openOrFocusFavoritesTab()
    local existingIndex = findFirstTabByUrlPrefix("about:favorites")
    if existingIndex then
        activateTab(existingIndex)
        return
    end

    local tab = newTab("about:favorites")
    navigate("about:favorites", true, false, tab)
end

local function openOrFocusHistoryTab()
    local existingIndex = findFirstTabByUrlPrefix("about:history")
    if existingIndex then
        activateTab(existingIndex)
        return
    end

    local tab = newTab("about:history")
    navigate("about:history", true, false, tab)
end

local function pageLineToPrintableText(line, width)
    local limit = math.max(1, tonumber(width) or 1)
    local highest = 0
    local chars = (line and line.chars) or {}
    for index, ch in pairs(chars) do
        if ch and ch ~= " " and index > highest and index <= limit then
            highest = index
        end
    end
    if highest <= 0 then
        return ""
    end
    local out = {}
    for x = 1, highest do
        out[x] = chars[x] or " "
    end
    return table.concat(out)
end

local function printablePageLines(tab)
    local target = tab or activeTab()
    local terminalWidth = term and term.getSize and term.getSize() or 1
    local width = math.max(1, tonumber(target.viewportWidth) or tonumber(terminalWidth) or 1)
    local lines = target.pageLines or { createEmptyLine() }
    local totalLines = math.max(1, pageLineCount(target))

    if turtleModeEnabled() and target.document then
        local fullLines = renderDocumentLines(
            target.document,
            width,
            target.formState,
            target.focusedFormControl
        )
        if type(fullLines) == "table" and #fullLines > 0 then
            lines = fullLines
            totalLines = math.max(1, #fullLines)
        end
    end

    local output = {}
    for index = 1, totalLines do
        output[#output + 1] = pageLineToPrintableText(lines[index], width)
    end
    while #output > 1 and output[#output] == "" do
        table.remove(output)
    end
    return output
end

local function printCurrentPage(tab)
    local target = tab or activeTab()
    local lines = printablePageLines(target)
    local outputDir = fs.combine(SCRIPT_DIR, "prints")
    if not fs.exists(outputDir) then
        fs.makeDir(outputDir)
    end

    local stamp = nil
    if os and type(os.date) == "function" then
        local okDate, dateText = pcall(os.date, "%Y%m%d-%H%M%S")
        if okDate and dateText and dateText ~= "" then
            stamp = tostring(dateText)
        end
    end
    if not stamp then
        stamp = tostring(math.floor(((os and type(os.clock) == "function") and os.clock() or 0) * 1000))
    end

    local baseName = "page-" .. stamp
    local candidate = fs.combine(outputDir, baseName .. ".txt")
    local nextSuffix = 1
    while fs.exists(candidate) do
        candidate = fs.combine(outputDir, ("%s-%d.txt"):format(baseName, nextSuffix))
        nextSuffix = nextSuffix + 1
    end

    local handle = fs.open(candidate, "w")
    if not handle then
        target.status = "Print failed: could not open output file"
        return false
    end

    local pageTitle = trim((target.document and target.document.title) or "")
    if pageTitle == "" then
        pageTitle = trim(target.currentUrl or "")
    end
    handle.writeLine("Title: " .. pageTitle)
    handle.writeLine("URL: " .. trim(target.currentUrl or ""))
    if os and type(os.date) == "function" then
        local okDate, dateText = pcall(os.date, "%Y-%m-%d %H:%M:%S")
        if okDate and dateText then
            handle.writeLine("Printed: " .. tostring(dateText))
        end
    end
    handle.writeLine("")
    for _, line in ipairs(lines) do
        handle.writeLine(line)
    end
    handle.close()

    target.status = "Printed to " .. candidate
    return true
end

local function toggleCurrentPageFavorite()
    local tab = activeTab()
    local currentUrl = trim(tab.currentUrl or "")
    if not canFavoriteUrl(currentUrl) then
        return false, "Cannot favorite about pages"
    end
    if isFavoriteUrl(currentUrl) then
        return removeBrowserFavorite(currentUrl)
    end
    local title = trim((tab.document and tab.document.title) or "")
    return addBrowserFavorite(currentUrl, title)
end

local function hitMenuPanel(x, y)
    local menu = state.ui.menu
    local panel = menu and menu.panel or nil
    if not panel then
        return false
    end
    return x >= panel.x1 and x <= panel.x2 and y >= panel.y1 and y <= panel.y2
end

local function handleMenuClick(x, y)
    local menu = state.ui.menu
    if not menu then
        return false
    end

    if hitRegion(x, y, menu.settings) then
        state.menuOpen = false
        openOrFocusSettingsTab()
        return true
    end
    if hitRegion(x, y, menu.help) then
        state.menuOpen = false
        openHelpTab()
        return true
    end
    if hitRegion(x, y, menu.addFavorite) then
        if menu.addFavoriteEnabled then
            toggleCurrentPageFavorite()
        end
        return true
    end
    if hitRegion(x, y, menu.favorites) then
        state.menuOpen = false
        openOrFocusFavoritesTab()
        return true
    end
    if hitRegion(x, y, menu.history) then
        state.menuOpen = false
        openOrFocusHistoryTab()
        return true
    end
    if hitRegion(x, y, menu.print) then
        state.menuOpen = false
        printCurrentPage()
        return true
    end
    if hitRegion(x, y, menu.exit) then
        state.menuOpen = false
        state.running = false
        return true
    end
    if hitMenuPanel(x, y) then
        return true
    end

    return true
end

local function urlEncode(value)
    local source = tostring(value or "")
    return (source:gsub("([^%w%-_%.~])", function(ch)
        return ("%%%02X"):format(string.byte(ch))
    end))
end

local function encodeFormFields(fields)
    local parts = {}
    for _, field in ipairs(fields or {}) do
        local name = urlEncode(field.name or "")
        local value = urlEncode(field.value or "")
        parts[#parts + 1] = name .. "=" .. value
    end
    return table.concat(parts, "&")
end

local function appendQuery(url, query)
    local base = tostring(url or "")
    local extra = tostring(query or "")
    if extra == "" then
        return base
    end

    local fragment = ""
    local hashAt = base:find("#", 1, true)
    if hashAt then
        fragment = base:sub(hashAt)
        base = base:sub(1, hashAt - 1)
    end

    local sep = base:find("?", 1, true) and "&" or "?"
    return base .. sep .. extra .. fragment
end

local function formControl(tab, key)
    local target = tab or activeTab()
    local meta = target.formMeta or {}
    local controls = meta.controlsByKey or {}
    local control = controls[key]
    if not control then
        return nil, nil
    end
    target.formState = target.formState or {}
    local stateEntry = target.formState[key]
    if not stateEntry then
        stateEntry = {}
        target.formState[key] = stateEntry
    end
    return control, stateEntry
end

local function isEditableFormControl(control)
    if not control or control.disabled or control.readonly then
        return false
    end
    if control.tag == "textarea" then
        return true
    end
    if control.tag ~= "input" then
        return false
    end
    local inputType = tostring(control.inputType or "text"):lower()
    if inputType == "hidden"
        or inputType == "checkbox"
        or inputType == "radio"
        or inputType == "submit"
        or inputType == "reset"
        or inputType == "button"
        or inputType == "image" then
        return false
    end
    return true
end

local function setFocusedFormControl(tab, key)
    local target = tab or activeTab()
    local changed = target.focusedFormControl ~= key or target.urlFocus
    target.focusedFormControl = key
    target.urlFocus = false
    clearUrlSelection(target)
    if changed then
        bumpRenderRevision(target)
    end
end

local function clampControlCursor(stateEntry)
    local value = tostring(stateEntry.value or "")
    local cursor = tonumber(stateEntry.cursor) or (#value + 1)
    stateEntry.cursor = clamp(math.floor(cursor), 1, #value + 1)
end

local function insertIntoFormControl(stateEntry, control, text)
    local value = tostring(stateEntry.value or "")
    local cursor = tonumber(stateEntry.cursor) or (#value + 1)
    cursor = clamp(math.floor(cursor), 1, #value + 1)

    local insertion = tostring(text or "")
    if insertion == "" then
        return
    end

    local before = value:sub(1, cursor - 1)
    local after = value:sub(cursor)
    local merged = before .. insertion .. after
    if control and control.maxLength and tonumber(control.maxLength) then
        merged = merged:sub(1, math.max(0, tonumber(control.maxLength)))
    end
    stateEntry.value = merged
    stateEntry.cursor = clamp(cursor + #insertion, 1, #merged + 1)
end

local function removeFromFormControl(stateEntry, backward)
    local value = tostring(stateEntry.value or "")
    local cursor = tonumber(stateEntry.cursor) or (#value + 1)
    cursor = clamp(math.floor(cursor), 1, #value + 1)
    if backward then
        if cursor <= 1 then
            return
        end
        local before = value:sub(1, cursor - 2)
        local after = value:sub(cursor)
        stateEntry.value = before .. after
        stateEntry.cursor = cursor - 1
    else
        if cursor > #value then
            return
        end
        local before = value:sub(1, cursor - 1)
        local after = value:sub(cursor + 1)
        stateEntry.value = before .. after
        stateEntry.cursor = cursor
    end
    clampControlCursor(stateEntry)
end

local function resetForm(tab, formId)
    local target = tab or activeTab()
    local meta = target.formMeta or {}
    local forms = meta.formsById or {}
    local controls = meta.controlsByKey or {}
    local form = forms[formId]
    if not form then
        return false
    end

    target.formState = target.formState or {}
    for _, key in ipairs(form.controlKeys or {}) do
        local control = controls[key]
        if control then
            local nextState = {}
            for defaultKey, defaultValue in pairs(control.defaults or {}) do
                if type(defaultValue) == "table" then
                    local copied = {}
                    for i, value in ipairs(defaultValue) do
                        copied[i] = value
                    end
                    nextState[defaultKey] = copied
                else
                    nextState[defaultKey] = defaultValue
                end
            end
            target.formState[key] = nextState
        end
    end
    bumpRenderRevision(target)
    return true
end

local function collectFormFields(tab, formId, submitterKey)
    local target = tab or activeTab()
    local meta = target.formMeta or {}
    local forms = meta.formsById or {}
    local controls = meta.controlsByKey or {}
    local form = forms[formId]
    if not form then
        return {}
    end

    local fields = {}
    for _, key in ipairs(form.controlKeys or {}) do
        local control = controls[key]
        local stateEntry = target.formState and target.formState[key] or nil
        if control and not control.disabled then
            local name = trim(tostring(control.name or ""))
            if control.tag == "input" then
                local inputType = tostring(control.inputType or "text"):lower()
                if inputType == "submit" or inputType == "image" then
                    if key == submitterKey and name ~= "" then
                        fields[#fields + 1] = {
                            name = name,
                            value = tostring((stateEntry and stateEntry.value) or control.defaultValue or ""),
                        }
                    end
                elseif inputType == "reset" or inputType == "button" then
                    -- Never included in payload.
                elseif inputType == "checkbox" or inputType == "radio" then
                    if stateEntry and stateEntry.checked and name ~= "" then
                        fields[#fields + 1] = {
                            name = name,
                            value = tostring(stateEntry.value or control.defaultValue or "on"),
                        }
                    end
                else
                    if name ~= "" then
                        fields[#fields + 1] = {
                            name = name,
                            value = tostring((stateEntry and stateEntry.value) or control.defaultValue or ""),
                        }
                    end
                end
            elseif control.tag == "textarea" then
                if name ~= "" then
                    fields[#fields + 1] = {
                        name = name,
                        value = tostring((stateEntry and stateEntry.value) or control.defaultValue or ""),
                    }
                end
            elseif control.tag == "select" then
                if name ~= "" then
                    local options = control.options or {}
                    if control.multiple then
                        local selected = (stateEntry and stateEntry.selectedIndices) or {}
                        for _, index in ipairs(selected) do
                            local option = options[index]
                            if option then
                                fields[#fields + 1] = {
                                    name = name,
                                    value = tostring(option.value or option.label or ""),
                                }
                            end
                        end
                    else
                        local index = stateEntry and tonumber(stateEntry.selectedIndex) or control.defaultSelectedIndex or 1
                        index = clamp(math.floor(index or 1), 1, math.max(1, #options))
                        local option = options[index]
                        if option then
                            fields[#fields + 1] = {
                                name = name,
                                value = tostring(option.value or option.label or ""),
                            }
                        end
                    end
                end
            elseif control.tag == "button" then
                local buttonType = tostring(control.buttonType or "submit"):lower()
                if buttonType == "submit" and key == submitterKey and name ~= "" then
                    fields[#fields + 1] = {
                        name = name,
                        value = tostring((stateEntry and stateEntry.value) or control.value or control.defaultValue or ""),
                    }
                end
            end
        end
    end

    return fields
end

local function refreshCurrentDocumentWithoutNavigation(tab)
    local target = tab or activeTab()
    local currentUrl = trim(target.currentUrl or "")
    if currentUrl == "" then
        return false
    end
    state.highUsage.loadingFrame = true
    local previousScroll = target.scroll or 0
    local previousFormState = target.formState or {}
    local previousFocusedControl = target.focusedFormControl
    local wasUrlFocused = target.urlFocus
    local previousUrlInput = target.urlInput or currentUrl
    local previousUrlCursor = target.urlCursor or (#previousUrlInput + 1)
    local previousUrlOffset = target.urlOffset or 0
    local previousUrlSelStart = target.urlSelStart
    local previousUrlSelEnd = target.urlSelEnd

    local body, finalUrl, headers, err = fetchTextResource(currentUrl, false)
    if not body then
        finalUrl = currentUrl
        body = makeErrorPage(finalUrl, err or "Unknown error")
        headers = { ["Content-Type"] = "text/html" }
    end

    local contentType = getHeader(headers, "Content-Type") or ""
    if not looksLikeHtml(body, contentType) then
        body = "<html><body><pre>" .. escapeHtml(body) .. "</pre></body></html>"
    end

    local resolvedUrl = finalUrl or currentUrl
    target.document = buildDocument(body, resolvedUrl)
    target.currentUrl = resolvedUrl
    target.aboutUpdateIntervalMs = parseAboutUpdateIntervalMs(headers)
    target.settingsStickyStatus = parseSettingsStatusMessage(headers, resolvedUrl)
    target.status = target.document.title or target.status
    if wasUrlFocused then
        target.urlInput = previousUrlInput
        target.urlCursor = clamp(previousUrlCursor, 1, #target.urlInput + 1)
        target.urlOffset = math.max(0, tonumber(previousUrlOffset) or 0)
        target.urlFocus = true
        target.urlSelStart = previousUrlSelStart
        target.urlSelEnd = previousUrlSelEnd
    else
        target.urlInput = resolvedUrl
        target.urlCursor = #target.urlInput + 1
        target.urlOffset = 0
        target.urlFocus = false
        clearUrlSelection(target)
    end
    target.formState = previousFormState
    target.formMeta = nil
    target.focusedFormControl = previousFocusedControl
    target.renderRevision = 0
    target.lastRenderSignature = nil
    target.scroll = previousScroll
    renderDocument(target)
    if scheduleAboutUpdateTimer then
        scheduleAboutUpdateTimer()
    end
    return true
end

local function submitForm(tab, formId, submitterKey)
    local target = tab or activeTab()
    local meta = target.formMeta or {}
    local forms = meta.formsById or {}
    local controls = meta.controlsByKey or {}
    local form = forms[formId]
    if not form then
        return false
    end

    local submitter = submitterKey and controls[submitterKey] or nil
    local rawMethod = submitter and trim(submitter.formMethod or "") or ""
    if rawMethod == "" then
        rawMethod = trim(form.method or "")
    end
    rawMethod = rawMethod:lower()
    if rawMethod ~= "post" then
        rawMethod = "get"
    end

    local action = submitter and trim(submitter.formAction or "") or ""
    if action == "" then
        action = trim(form.action or "")
    end
    if action == "" then
        action = target.currentUrl or "about:blank"
    end
    action = core.resolveRelativeUrl(target.currentUrl or action, action)

    local fields = collectFormFields(target, formId, submitterKey)
    local encoded = encodeFormFields(fields)
    local requestUrl = action
    local requestOptions = {
        method = rawMethod:upper(),
    }

    if rawMethod == "post" then
        local enctype = submitter and trim(submitter.formEnctype or "") or ""
        if enctype == "" then
            enctype = trim(form.enctype or "")
        end
        if enctype == "" then
            enctype = "application/x-www-form-urlencoded"
        end

        requestOptions.headers = {
            ["Content-Type"] = enctype,
        }
        requestOptions.body = encoded
    else
        requestUrl = appendQuery(action, encoded)
    end

    local _, _, _, err = fetchTextResource(requestUrl, true, requestOptions)
    if err then
        target.status = "Form submit failed: " .. tostring(err)
        return false
    end

    target.status = "Form submitted"
    if startsWith(trim(target.currentUrl or ""):lower(), "about:") then
        refreshCurrentDocumentWithoutNavigation(target)
    end
    return true
end

local function cycleSelect(tab, control, stateEntry, direction)
    local target = tab or activeTab()
    local options = control.options or {}
    if #options == 0 then
        return false
    end
    local nextIndex = tonumber(stateEntry.selectedIndex) or control.defaultSelectedIndex or 1
    nextIndex = nextIndex + direction
    if nextIndex < 1 then
        nextIndex = #options
    elseif nextIndex > #options then
        nextIndex = 1
    end
    stateEntry.selectedIndex = nextIndex
    stateEntry.selectedIndices = { nextIndex }
    bumpRenderRevision(target)
    return true
end

local function activateFormControl(tab, key)
    local target = tab or activeTab()
    local control, stateEntry = formControl(target, key)
    if not control or control.disabled then
        return false
    end

    setFocusedFormControl(target, key)

    if control.tag == "input" then
        local inputType = tostring(control.inputType or "text"):lower()
        if inputType == "checkbox" then
            stateEntry.checked = not not stateEntry.checked
            bumpRenderRevision(target)
            return true
        end
        if inputType == "radio" then
            local formId = control.formId
            local name = trim(tostring(control.name or ""))
            if formId and name ~= "" then
                local form = target.formMeta and target.formMeta.formsById and target.formMeta.formsById[formId] or nil
                local controls = target.formMeta and target.formMeta.controlsByKey or {}
                for _, candidateKey in ipairs(form and form.controlKeys or {}) do
                    local candidate = controls[candidateKey]
                    if candidate
                        and candidate.tag == "input"
                        and tostring(candidate.inputType or ""):lower() == "radio"
                        and trim(tostring(candidate.name or "")) == name then
                        local candidateState = target.formState[candidateKey] or {}
                        candidateState.checked = candidateKey == key
                        target.formState[candidateKey] = candidateState
                    end
                end
            else
                stateEntry.checked = true
            end
            bumpRenderRevision(target)
            return true
        end
        if inputType == "submit" or inputType == "image" then
            if control.formId then
                return submitForm(target, control.formId, key)
            end
            return true
        end
        if inputType == "reset" then
            if control.formId then
                return resetForm(target, control.formId)
            end
            return true
        end
        stateEntry.cursor = #tostring(stateEntry.value or "") + 1
        bumpRenderRevision(target)
        return true
    end

    if control.tag == "textarea" then
        stateEntry.cursor = #tostring(stateEntry.value or "") + 1
        bumpRenderRevision(target)
        return true
    end

    if control.tag == "select" then
        return cycleSelect(target, control, stateEntry, 1)
    end

    if control.tag == "button" then
        local buttonType = tostring(control.buttonType or "submit"):lower()
        if buttonType == "reset" then
            if control.formId then
                return resetForm(target, control.formId)
            end
            return true
        end
        if buttonType == "submit" and control.formId then
            return submitForm(target, control.formId, key)
        end
        bumpRenderRevision(target)
        return true
    end

    return false
end

local function moveFocusedFormControl(tab, direction)
    local target = tab or activeTab()
    local meta = target.formMeta or {}
    local order = meta.controlOrder or {}
    if #order == 0 then
        return false
    end

    local startIndex = 0
    for index, key in ipairs(order) do
        if key == target.focusedFormControl then
            startIndex = index
            break
        end
    end

    local size = #order
    for offset = 1, size do
        local index = ((startIndex - 1 + (offset * direction)) % size) + 1
        local key = order[index]
        local control = meta.controlsByKey and meta.controlsByKey[key] or nil
        if control and not control.disabled and tostring(control.inputType or ""):lower() ~= "hidden" then
            setFocusedFormControl(target, key)
            local stateEntry = target.formState[key] or {}
            if isEditableFormControl(control) then
                stateEntry.cursor = #tostring(stateEntry.value or "") + 1
                target.formState[key] = stateEntry
            end
            return true
        end
    end

    return false
end

local function handleFocusedFormControlKey(tab, key)
    local target = tab or activeTab()
    if not target.focusedFormControl then
        return false
    end

    local control, stateEntry = formControl(target, target.focusedFormControl)
    if not control then
        target.focusedFormControl = nil
        return false
    end

    if key == keys.escape then
        target.focusedFormControl = nil
        return true
    end

    if key == keys.tab then
        local direction = state.shiftDown and -1 or 1
        return moveFocusedFormControl(target, direction)
    end

    if key == keys.enter then
        if control.tag == "textarea" and isEditableFormControl(control) then
            insertIntoFormControl(stateEntry, control, "\n")
            return true
        end
        if control.tag == "input" then
            local inputType = tostring(control.inputType or "text"):lower()
            if inputType == "reset" or inputType == "submit" or inputType == "image" then
                return activateFormControl(target, control.key)
            end
            if inputType == "button" then
                return true
            end
        elseif control.tag == "button" then
            local buttonType = tostring(control.buttonType or "submit"):lower()
            if buttonType == "reset" or buttonType == "submit" then
                return activateFormControl(target, control.key)
            end
            if buttonType == "button" then
                return true
            end
        end
        if control.formId then
            return submitForm(target, control.formId, control.key)
        end
        return true
    end

    if key == keys.space then
        if control.tag == "input" then
            local inputType = tostring(control.inputType or "text"):lower()
            if inputType == "checkbox" or inputType == "radio" or inputType == "submit" or inputType == "reset" or inputType == "button" then
                return activateFormControl(target, control.key)
            end
        elseif control.tag == "select" or control.tag == "button" then
            return activateFormControl(target, control.key)
        end
    end

    if control.tag == "input" then
        local inputType = tostring(control.inputType or "text"):lower()
        if (inputType == "number" or inputType == "range")
            and (key == keys.up or key == keys.down)
            and isEditableFormControl(control) then
            local value = tonumber(stateEntry.value or control.defaultValue or "0") or 0
            local step = tonumber(control.stepValue) or 1
            if step == 0 then
                step = 1
            end
            local direction = (key == keys.up) and 1 or -1
            local nextValue = value + (step * direction)
            if tonumber(control.minValue) then
                nextValue = math.max(nextValue, tonumber(control.minValue))
            end
            if tonumber(control.maxValue) then
                nextValue = math.min(nextValue, tonumber(control.maxValue))
            end
            stateEntry.value = tostring(nextValue)
            stateEntry.cursor = #stateEntry.value + 1
            return true
        end
    end

    if control.tag == "select" then
        if key == keys.left or key == keys.up then
            return cycleSelect(target, control, stateEntry, -1)
        elseif key == keys.right or key == keys.down then
            return cycleSelect(target, control, stateEntry, 1)
        end
    end

    if not isEditableFormControl(control) then
        return true
    end

    clampControlCursor(stateEntry)
    if key == keys.left then
        stateEntry.cursor = clamp(stateEntry.cursor - 1, 1, #tostring(stateEntry.value or "") + 1)
        return true
    elseif key == keys.right then
        stateEntry.cursor = clamp(stateEntry.cursor + 1, 1, #tostring(stateEntry.value or "") + 1)
        return true
    elseif key == keys.home then
        stateEntry.cursor = 1
        return true
    elseif key == keys["end"] then
        stateEntry.cursor = #tostring(stateEntry.value or "") + 1
        return true
    elseif key == keys.backspace then
        removeFromFormControl(stateEntry, true)
        return true
    elseif key == keys.delete then
        removeFromFormControl(stateEntry, false)
        return true
    end

    return true
end

local function handleFocusedFormControlChar(tab, character)
    local target = tab or activeTab()
    if not target.focusedFormControl then
        return false
    end
    local control, stateEntry = formControl(target, target.focusedFormControl)
    if not control or not isEditableFormControl(control) then
        return false
    end
    insertIntoFormControl(stateEntry, control, character)
    return true
end

local function handleFocusedFormControlPaste(tab, text)
    local target = tab or activeTab()
    if not target.focusedFormControl then
        return false
    end
    local control, stateEntry = formControl(target, target.focusedFormControl)
    if not control or not isEditableFormControl(control) then
        return false
    end
    insertIntoFormControl(stateEntry, control, text or "")
    return true
end

local function loadDocumentWithAbort(tab, normalized, allowFallback, requestOptions)
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

navigate = function(rawInput, addToHistory, allowFallback, tab, requestOptions)
    local target = tab or activeTab()
    local normalized, inferred = normalizeInputUrl(rawInput)
    state.highUsage.loadingFrame = true

    target.loading = true
    target.status = "Loading " .. normalized
    target.urlInput = normalized
    target.urlCursor = #target.urlInput + 1
    target.urlOffset = 0
    clearUrlSelection(target)
    draw()

    local result, aborted = loadDocumentWithAbort(target, normalized, allowFallback or inferred, requestOptions)
    target.loading = false
    if aborted then
        target.status = "Load aborted"
        draw()
        if scheduleAboutUpdateTimer then
            scheduleAboutUpdateTimer()
        end
        return false
    end

    local finalUrl = normalized
    local document = nil
    if result then
        finalUrl = result.finalUrl or finalUrl
        if result.document then
            document = result.document
        end
    end
    if not document then
        document = buildDocument(makeErrorPage(normalized, "Unknown error"), normalized)
    end

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
    target.aboutUpdateIntervalMs = result and result.aboutUpdateIntervalMs or nil
    target.settingsStickyStatus = result and result.settingsStickyStatus or nil

    if addToHistory then
        pushHistory(target, finalUrl)
    elseif target.historyIndex > 0 then
        target.history[target.historyIndex] = finalUrl
    else
        pushHistory(target, finalUrl)
    end
    if shouldTrackNavigationInHistory(normalized) then
        addBrowserHistory(finalUrl, target.document and target.document.title or "")
    end

    target.scroll = 0
    renderDocument(target)
    draw()
    if scheduleAboutUpdateTimer then
        scheduleAboutUpdateTimer()
    end
    return true
end

local function goBack()
    local tab = activeTab()
    if not canGoBack(tab) then
        return
    end
    tab.historyIndex = tab.historyIndex - 1
    navigate(tab.history[tab.historyIndex], false, false, tab)
end

local function goForward()
    local tab = activeTab()
    if not canGoForward(tab) then
        return
    end
    tab.historyIndex = tab.historyIndex + 1
    navigate(tab.history[tab.historyIndex], false, false, tab)
end

local function reloadPage()
    local tab = activeTab()
    if tab.loading then
        return
    end
    if not tab.currentUrl then
        return
    end
    navigate(tab.currentUrl, false, false, tab)
end

local function insertUrlText(text)
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

local function deleteUrlBack()
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

local function deleteUrlForward()
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

local function handleTabClick(button, x)
    if hitRegion(x, 1, state.ui.closeBrowser) then
        state.running = false
        return
    end

    if hitRegion(x, 1, state.ui.newTab) then
        local newTabUrl = homePageUrl()
        local tab = newTab(newTabUrl)
        navigate(newTabUrl, true, false, tab)
        tab.urlFocus = true
        tab.urlCursor = #tab.urlInput + 1
        clearUrlSelection(tab)
        return
    end

    if button == 1 then
        local closeIndex = tabCloseIndexAt(x)
        if closeIndex then
            closeTab(closeIndex)
            return
        end
    end

    local index = tabIndexAt(x)
    if not index then
        local tab = activeTab()
        tab.urlFocus = false
        clearUrlSelection(tab)
        tab.focusedFormControl = nil
        return
    end

    local now = os.clock()
    local wasDoubleClick = button == 1
        and state.lastTabClick.button == button
        and state.lastTabClick.index == index
        and (now - (state.lastTabClick.at or 0)) <= 0.35

    if button == 1 and state.expandedTabIndex == index then
        collapseExpandedTab()
        state.tabDrag = nil
        state.scrollbarDrag = nil
        activateTab(index)
        clearUrlSelection(activeTab())
        state.lastTabClick = {
            index = nil,
            button = nil,
            at = 0,
        }
        return
    end

    activateTab(index)
    clearUrlSelection(activeTab())

    if wasDoubleClick then
        toggleExpandedTab(index)
        state.tabDrag = nil
        state.scrollbarDrag = nil
        state.lastTabClick = {
            index = nil,
            button = nil,
            at = 0,
        }
        return
    end

    state.lastTabClick = {
        index = index,
        button = button,
        at = now,
    }

    if button == 1 and not state.expandedTabIndex then
        state.tabDrag = { button = button, index = index }
    end
end

local function handleToolbarClick(x)
    local tab = activeTab()
    if hitRegion(x, 2, state.ui.menuButton) then
        state.menuOpen = not state.menuOpen
        if state.menuOpen then
            tab.urlFocus = false
            clearUrlSelection(tab)
            tab.focusedFormControl = nil
        end
        state.tabDrag = nil
        state.scrollbarDrag = nil
        return
    end

    state.menuOpen = false

    if hitRegion(x, 2, state.ui.back) then
        tab.focusedFormControl = nil
        goBack()
        return
    end
    if hitRegion(x, 2, state.ui.forward) then
        tab.focusedFormControl = nil
        goForward()
        return
    end
    if hitRegion(x, 2, state.ui.reload) then
        tab.focusedFormControl = nil
        reloadPage()
        return
    end
    if hitRegion(x, 2, state.ui.url) then
        tab.urlFocus = true
        tab.focusedFormControl = nil
        local pos = tab.urlOffset + (x - state.ui.url.x1) + 1
        tab.urlCursor = clamp(pos, 1, #tab.urlInput + 1)
        clearUrlSelection(tab)
        return
    end
    tab.urlFocus = false
    clearUrlSelection(tab)
    tab.focusedFormControl = nil
end

local function handleMouseClick(button, x, y)
    layoutUi()

    if state.menuOpen then
        if hitMenuPanel(x, y) then
            handleMenuClick(x, y)
            return
        end
        if not hitRegion(x, y, state.ui.menuButton) then
            state.menuOpen = false
        end
    end

    if y == 1 then
        handleTabClick(button, x)
        return
    end

    if y == 2 then
        handleToolbarClick(x)
        return
    end

    local tab = activeTab()
    tab.urlFocus = false
    clearUrlSelection(tab)

    local scrollbar = verticalScrollbarMetrics(tab)
    if scrollbar and x == scrollbar.x then
        if button ~= 1 then
            return
        end
        if scrollbar.maxScroll <= 0 then
            return
        end

        local clickRow = clamp(y - TOP_BAR_ROWS, 1, scrollbar.viewportHeight)
        local thumbBottom = scrollbar.thumbTop + scrollbar.thumbHeight - 1
        if clickRow >= scrollbar.thumbTop and clickRow <= thumbBottom then
            state.scrollbarDrag = {
                button = button,
                tab = tab,
                grabOffset = clickRow - scrollbar.thumbTop,
            }
        elseif clickRow < scrollbar.thumbTop then
            setScroll(tab.scroll - scrollbar.viewportHeight, tab)
        elseif clickRow > thumbBottom then
            setScroll(tab.scroll + scrollbar.viewportHeight, tab)
        end
        return
    end

    local viewportWidth = pageContentWidth(tab)
    local lineIndex = clamp(tab.scroll + (y - TOP_BAR_ROWS), 1, pageLineCount(tab))
    local column = clamp(x, 1, viewportWidth)
    if state.caretMode then
        if button == 1 then
            setPageSelection(tab, lineIndex, column, lineIndex, column)
        end
        return
    end

    clearPageSelection(tab)
    local line = tab.pageLines[lineIndex]
    local controlKey = line and line.controls and line.controls[column] or nil
    if controlKey then
        state.menuOpen = false
        activateFormControl(tab, controlKey)
        return
    end
    tab.focusedFormControl = nil
    local href = line and line.links and line.links[column] or nil
    if href then
        state.menuOpen = false
        navigate(href, true, false, tab)
    end
end

local function handleMouseDrag(button, x, y)
    if state.scrollbarDrag and state.scrollbarDrag.button == button then
        local drag = state.scrollbarDrag
        local tab = drag.tab or activeTab()
        if tab ~= activeTab() then
            state.scrollbarDrag = nil
            return
        end

        local scrollbar = verticalScrollbarMetrics(tab)
        if not scrollbar then
            state.scrollbarDrag = nil
            return
        end

        local row = clamp(y - TOP_BAR_ROWS, 1, scrollbar.viewportHeight)
        local travel = scrollbar.viewportHeight - scrollbar.thumbHeight
        if travel <= 0 or scrollbar.maxScroll <= 0 then
            setScroll(0, tab)
            return
        end

        local thumbTop = clamp(row - (drag.grabOffset or 0), 1, travel + 1)
        local ratio = (thumbTop - 1) / travel
        setScroll(math.floor((ratio * scrollbar.maxScroll) + 0.5), tab)
        return
    end

    if state.tabDrag and state.tabDrag.button == button then
        if state.expandedTabIndex then
            return
        end
        if y ~= 1 then
            return
        end

        layoutUi()
        local target = tabIndexAt(x)
        if not target then
            if x < 1 then
                target = 1
            elseif x > state.ui.newTab.x1 then
                target = #state.tabs
            end
        end

        if target and target ~= state.tabDrag.index then
            moveTab(state.tabDrag.index, target)
            state.tabDrag.index = target
            layoutUi()
        end
        return
    end

    if not state.caretMode then
        return
    end
    if button ~= 1 or y <= TOP_BAR_ROWS then
        return
    end

    local tab = activeTab()
    if not tab.pageSelection then
        return
    end

    local w = pageContentWidth(tab)
    local lineIndex = clamp(tab.scroll + (y - TOP_BAR_ROWS), 1, pageLineCount(tab))
    local column = clamp(x, 1, w)
    tab.pageSelection.endLine = lineIndex
    tab.pageSelection.endCol = column
end

local function handleMouseUp(button, _, _)
    if state.tabDrag and state.tabDrag.button == button then
        state.tabDrag = nil
    end
    if state.scrollbarDrag and state.scrollbarDrag.button == button then
        state.scrollbarDrag = nil
    end
end

local function handleMouseScroll(direction, _, y)
    if y <= TOP_BAR_ROWS then
        return
    end
    local tab = activeTab()
    setScroll(tab.scroll + direction, tab)
end

local function focusUrlBar()
    local tab = activeTab()
    tab.urlFocus = true
    tab.urlCursor = #tab.urlInput + 1
    clearUrlSelection(tab)
end

local function handleUrlKey(key)
    local tab = activeTab()
    if key == keys.enter then
        navigate(tab.urlInput, true, true, tab)
    elseif key == keys.left then
        local startPos, _ = getUrlSelection(tab)
        if startPos then
            tab.urlCursor = startPos
            clearUrlSelection(tab)
        else
            tab.urlCursor = clamp(tab.urlCursor - 1, 1, #tab.urlInput + 1)
        end
    elseif key == keys.right then
        local _, endPos = getUrlSelection(tab)
        if endPos then
            tab.urlCursor = endPos
            clearUrlSelection(tab)
        else
            tab.urlCursor = clamp(tab.urlCursor + 1, 1, #tab.urlInput + 1)
        end
    elseif key == keys.home then
        tab.urlCursor = 1
        clearUrlSelection(tab)
    elseif key == keys["end"] then
        tab.urlCursor = #tab.urlInput + 1
        clearUrlSelection(tab)
    elseif key == keys.backspace then
        deleteUrlBack()
    elseif key == keys.delete then
        deleteUrlForward()
    elseif key == keys.escape then
        tab.urlFocus = false
        tab.urlInput = tab.currentUrl
        tab.urlCursor = #tab.urlInput + 1
        clearUrlSelection(tab)
    end
end

local function handleNavigationKey(key)
    local tab = activeTab()
    if state.caretMode then
        local w = pageContentWidth(tab)
        local maxLine = pageLineCount(tab)
        local selection = tab.pageSelection
        if not selection then
            local startLine = clamp(tab.scroll + 1, 1, maxLine)
            selection = {
                startLine = startLine,
                startCol = 1,
                endLine = startLine,
                endCol = 1,
            }
            tab.pageSelection = selection
        end

        local line = clamp(selection.endLine or 1, 1, maxLine)
        local col = clamp(selection.endCol or 1, 1, w)
        local newLine = line
        local newCol = col

        if key == keys.left then
            newCol = col - 1
            if newCol < 1 then
                newLine = math.max(1, line - 1)
                newCol = w
            end
        elseif key == keys.right then
            newCol = col + 1
            if newCol > w then
                newLine = math.min(maxLine, line + 1)
                newCol = 1
            end
        elseif key == keys.up then
            newLine = line - 1
        elseif key == keys.down then
            newLine = line + 1
        elseif key == keys.pageUp then
            newLine = line - pageHeight()
        elseif key == keys.pageDown then
            newLine = line + pageHeight()
        elseif key == keys.home then
            newCol = 1
        elseif key == keys["end"] then
            newCol = w
        else
            return
        end

        newLine = clamp(newLine, 1, maxLine)
        newCol = clamp(newCol, 1, w)
        if state.shiftDown then
            selection.endLine = newLine
            selection.endCol = newCol
        else
            selection.startLine = newLine
            selection.startCol = newCol
            selection.endLine = newLine
            selection.endCol = newCol
        end

        local visibleTop = tab.scroll + 1
        local visibleBottom = tab.scroll + pageHeight()
        if newLine < visibleTop then
            setScroll(newLine - 1, tab)
        elseif newLine > visibleBottom then
            setScroll(newLine - pageHeight(), tab)
        end
        return
    end

    if key == keys.up then
        setScroll(tab.scroll - 1, tab)
    elseif key == keys.down then
        setScroll(tab.scroll + 1, tab)
    elseif key == keys.pageUp then
        setScroll(tab.scroll - pageHeight(), tab)
    elseif key == keys.pageDown then
        setScroll(tab.scroll + pageHeight(), tab)
    elseif key == keys.home then
        setScroll(0, tab)
    elseif key == keys["end"] then
        setScroll(maxScroll(tab), tab)
    end
end

local function selectAllText()
    local tab = activeTab()
    if tab.urlFocus then
        tab.urlSelStart = 1
        tab.urlSelEnd = #tab.urlInput + 1
        tab.urlCursor = #tab.urlInput + 1
        return true
    end

    if tab.focusedFormControl then
        local control, stateEntry = formControl(tab, tab.focusedFormControl)
        if control and isEditableFormControl(control) then
            local value = tostring(stateEntry.value or "")
            stateEntry.cursor = #value + 1
            bumpRenderRevision(tab)
            return true
        end
    end

    if state.caretMode then
        selectAllPageText(tab)
        return true
    end

    return false
end

local function copySelectedText()
    local tab = activeTab()
    local text = ""
    if tab.urlFocus then
        text = getSelectedUrlText(tab)
        if text == "" then
            text = tab.urlInput or ""
        end
    elseif tab.focusedFormControl then
        local control, stateEntry = formControl(tab, tab.focusedFormControl)
        if control then
            if control.tag == "input" then
                local inputType = tostring(control.inputType or "text"):lower()
                if inputType == "checkbox" or inputType == "radio" then
                    text = stateEntry.checked and "true" or "false"
                else
                    text = tostring(stateEntry.value or control.defaultValue or "")
                end
            elseif control.tag == "select" then
                local options = control.options or {}
                local index = tonumber(stateEntry.selectedIndex) or control.defaultSelectedIndex or 1
                index = clamp(math.floor(index or 1), 1, math.max(1, #options))
                local option = options[index]
                if option then
                    text = tostring(option.value or option.label or "")
                end
            else
                text = tostring(stateEntry.value or control.defaultValue or "")
            end
        end
    elseif state.caretMode or tab.pageSelection then
        text = getSelectedPageText(tab)
    end

    if text ~= "" then
        state.clipboard = text
        state.localClipboardPendingPaste = true
        return true
    end
    return false
end

local function cutSelectedText()
    local tab = activeTab()
    if tab.urlFocus then
        local text = getSelectedUrlText(tab)
        if text == "" then
            return false
        end
        state.clipboard = text
        state.localClipboardPendingPaste = true
        deleteUrlSelection(tab)
        return true
    end

    if tab.focusedFormControl then
        local control, stateEntry = formControl(tab, tab.focusedFormControl)
        if control and isEditableFormControl(control) then
            local text = tostring(stateEntry.value or "")
            if text == "" then
                return false
            end
            state.clipboard = text
            state.localClipboardPendingPaste = true
            stateEntry.value = ""
            stateEntry.cursor = 1
            bumpRenderRevision(tab)
            return true
        end
    end

    if state.caretMode or tab.pageSelection then
        local text = getSelectedPageText(tab)
        if text == "" then
            return false
        end
        state.clipboard = text
        state.localClipboardPendingPaste = true
        return true
    end

    return false
end

local function pasteClipboardText()
    local tab = activeTab()
    if state.clipboard == nil or state.clipboard == "" then
        return false
    end

    if tab.urlFocus then
        insertUrlText(state.clipboard)
        state.localClipboardPendingPaste = false
        state.skipNextPaste = true
        return true
    end

    if tab.focusedFormControl then
        local control, stateEntry = formControl(tab, tab.focusedFormControl)
        if control and isEditableFormControl(control) then
            insertIntoFormControl(stateEntry, control, state.clipboard)
            state.localClipboardPendingPaste = false
            state.skipNextPaste = true
            bumpRenderRevision(tab)
            return true
        end
    end

    return false
end

local function handleKeyDown(key)
    if key ~= keys.v then
        state.skipNextPaste = false
    end

    if key == keys.leftCtrl or key == keys.rightCtrl then
        state.ctrlDown = true
        return
    end
    if key == keys.leftShift or key == keys.rightShift then
        state.shiftDown = true
        return
    end

    if state.menuOpen and key == keys.escape then
        state.menuOpen = false
        return
    end

    if key == keys.f5 then
        reloadPage()
        return
    end
    if key == keys.f7 then
        state.caretMode = not state.caretMode
        if state.caretMode then
            activeTab().focusedFormControl = nil
        end
        if not state.caretMode then
            for _, tabItem in ipairs(state.tabs) do
                clearPageSelection(tabItem)
            end
        end
        return
    end

    if state.ctrlDown then
        if key == keys.l then
            activeTab().focusedFormControl = nil
            focusUrlBar()
            return
        end
        if key == keys.r then
            reloadPage()
            return
        end
        if key == keys.a then
            selectAllText()
            return
        end
        if key == keys.c then
            copySelectedText()
            return
        end
        if key == keys.x then
            cutSelectedText()
            return
        end
        if key == keys.v then
            pasteClipboardText()
            return
        end
        if key == keys.t then
            local newTabUrl = homePageUrl()
            local tab = newTab(newTabUrl)
            navigate(newTabUrl, true, false, tab)
            tab.urlFocus = true
            tab.urlCursor = #tab.urlInput + 1
            clearUrlSelection(tab)
            return
        end
        if key == keys.w then
            closeActiveTab()
            return
        end
        if key == keys.tab then
            cycleTabs(1)
            return
        end
        if key == keys.q then
            state.running = false
            return
        end
        if key == keys.p then
            printCurrentPage()
            return
        end
        if key == keys.left then
            goBack()
            return
        end
        if key == keys.right then
            goForward()
            return
        end
    end

    local tab = activeTab()
    if tab.focusedFormControl then
        if handleFocusedFormControlKey(tab, key) then
            bumpRenderRevision(tab)
            return
        end
    end

    if key == keys.tab then
        tab.urlFocus = not tab.urlFocus
        if tab.urlFocus then
            tab.focusedFormControl = nil
            tab.urlCursor = #tab.urlInput + 1
            clearUrlSelection(tab)
        else
            clearUrlSelection(tab)
        end
        return
    end

    if tab.urlFocus then
        handleUrlKey(key)
        return
    end

    if key == keys.escape then
        state.running = false
        return
    end

    handleNavigationKey(key)
end

local function handleKeyUp(key)
    if key == keys.leftCtrl or key == keys.rightCtrl then
        state.ctrlDown = false
    elseif key == keys.leftShift or key == keys.rightShift then
        state.shiftDown = false
    end
end

scheduleAboutUpdateTimer = function()
    if not os.startTimer then
        return
    end

    local update = state.aboutUpdate
    local tab = activeTab()
    local intervalMs = tonumber(tab.aboutUpdateIntervalMs)
    local currentUrl = trim(tab.currentUrl or ""):lower()
    local shouldUpdate = (intervalMs and intervalMs > 0)
        and startsWith(currentUrl, "about:")
        and not tab.loading
        and not state.modal.open

    if not shouldUpdate then
        update.timer = nil
        update.tabIndex = nil
        update.intervalMs = nil
        return
    end

    intervalMs = math.floor(intervalMs + 0.5)
    if intervalMs < 1 then
        update.timer = nil
        update.tabIndex = nil
        update.intervalMs = nil
        return
    end

    if update.timer and update.tabIndex == state.activeTab and update.intervalMs == intervalMs then
        return
    end

    update.timer = nil
    update.tabIndex = state.activeTab
    update.intervalMs = intervalMs
    update.timer = os.startTimer(intervalMs / 1000)
end

scheduleAnimationTick = function()
    if not os.startTimer then
        return
    end
    if state.animationTimer then
        return
    end
    state.animationTimer = os.startTimer(ANIMATION_TICK_SECONDS)
end

local function handleTimer(timerId)
    if state.animationTimer and timerId == state.animationTimer then
        state.animationTimer = nil
        scheduleAnimationTick()
        return
    end

    local aboutUpdate = state.aboutUpdate
    if aboutUpdate.timer and timerId == aboutUpdate.timer then
        aboutUpdate.timer = nil
        aboutUpdate.tabIndex = nil
        aboutUpdate.intervalMs = nil

        local tab = activeTab()
        local currentUrl = trim(tab.currentUrl or ""):lower()
        if startsWith(currentUrl, "about:") and not tab.loading and not state.modal.open then
            refreshCurrentDocumentWithoutNavigation(tab)
        end
        if scheduleAboutUpdateTimer then
            scheduleAboutUpdateTimer()
        end
    end
end

local function handleChar(character)
    local byte = character and string.byte(character, 1) or nil
    if byte and byte >= 1 and byte <= 31 then
        if byte == 1 then
            selectAllText()
        elseif byte == 3 then
            copySelectedText()
        elseif byte == 24 then
            cutSelectedText()
        elseif byte == 22 then
            pasteClipboardText()
        end
        return
    end

    local tab = activeTab()
    if tab.urlFocus then
        insertUrlText(character)
        return
    end

    if handleFocusedFormControlChar(tab, character) then
        bumpRenderRevision(tab)
    end
end

local function resolvePasteText(text)
    local pasteText = text
    if state.localClipboardPendingPaste and state.clipboard ~= "" then
        pasteText = state.clipboard
        state.localClipboardPendingPaste = false
    end
    return pasteText
end

local function handlePaste(text)
    if state.skipNextPaste then
        state.skipNextPaste = false
        return
    end
    local tab = activeTab()
    local pasteText = resolvePasteText(text)
    if tab.urlFocus then
        if pasteText and pasteText ~= "" then
            insertUrlText(pasteText)
            state.clipboard = pasteText
        end
        return
    end
    if handleFocusedFormControlPaste(tab, pasteText) then
        bumpRenderRevision(tab)
        if pasteText and pasteText ~= "" then
            state.clipboard = pasteText
        end
    end
end

local function bootstrap(initialUrls)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
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

local function run(...)
    local initialUrls = { ... }
    bootstrap(initialUrls)
    while state.running do
        local event = { os.pullEvent() }
        local name = event[1]
        local frameStart = os.clock()
        state.highUsage.loadingFrame = false
        if state.skipNextPaste and name ~= "paste" and name ~= "key_up" then
            state.skipNextPaste = false
        end

        if state.highUsage.frozen and not state.modal.open then
            state.highUsage.frozen = false
            activateUsageGuard(state.highUsage.lastFrameMs or 0)
        end

        if state.modal.open then
            local hadModal = state.modal.open
            handleModalEvent(event)
            if state.running and (hadModal or state.modal.open) then
                draw()
            end
        else
            if name == "mouse_click" then
                handleMouseClick(event[2], event[3], event[4])
            elseif name == "mouse_drag" then
                handleMouseDrag(event[2], event[3], event[4])
            elseif name == "mouse_up" then
                handleMouseUp(event[2], event[3], event[4])
            elseif name == "mouse_scroll" then
                handleMouseScroll(event[2], event[3], event[4])
            elseif name == "key" then
                handleKeyDown(event[2])
            elseif name == "key_up" then
                handleKeyUp(event[2])
            elseif name == "char" then
                handleChar(event[2])
            elseif name == "paste" then
                handlePaste(event[2])
            elseif name == "timer" then
                handleTimer(event[2])
            elseif name == "term_resize" then
                rerenderAllTabs()
            end

            renderDocument(activeTab())
            draw()

            local guard = state.highUsage
            local frameMs = (os.clock() - frameStart) * 1000
            guard.lastFrameMs = frameMs

            if usageGuardEnabled() then
                local now = os.clock()
                local frameThreshold = HIGH_USAGE_FRAME_THRESHOLD_MS
                if guard.loadingFrame then
                    frameThreshold = HIGH_USAGE_FRAME_THRESHOLD_LOADING_MS
                end
                if now < (guard.cooldownUntil or 0) then
                    guard.overCount = 0
                elseif frameMs >= frameThreshold then
                    guard.overCount = (guard.overCount or 0) + 1
                    if guard.overCount >= HIGH_USAGE_STRIKE_LIMIT then
                        activateUsageGuard(frameMs)
                    end
                else
                    guard.overCount = 0
                end
            else
                guard.overCount = 0
                guard.frozen = false
                if state.modal.open and state.modal.spec and state.modal.spec.id == "high_usage_guard" then
                    clearModal()
                end
            end
        end
        if scheduleAboutUpdateTimer then
            scheduleAboutUpdateTimer()
        end
    end

    term.setCursorBlink(false)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    print(APP_TITLE .. " closed")
end

return run
