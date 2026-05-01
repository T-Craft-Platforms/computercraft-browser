function listBrowserSettings()
    local copied = {}
    for key, value in pairs(browserSettings) do
        copied[key] = tostring(value)
    end
    copied.browser_data_dir = currentBrowserDataDir()
    copied.downloads_dir = currentDownloadsDir()
    copied.logs_dir = currentLogsDir()
    copied.config_path = browserConfigPath()
    copied.history_path = browserHistoryPath()
    copied.default_monitor = tostring(browserSettings.default_monitor or INTERNAL_MONITOR_ID)
    copied.active_monitor = tostring(displayManager.getRuntimeDisplayTarget() or INTERNAL_MONITOR_ID)
    copied.available_monitors = table.concat(attachedMonitorNames(), ",")
    copied.monitor_override = tostring(displayManager.getStartupMonitorOverride() or "")
    copied.storage_ready = storageReady and "true" or "false"
    copied.storage_last_error = tostring(lastStorageError or "")
    local freeSpace = "unknown"
    local okFree, freeOrErr = pcall(fs.getFreeSpace, currentBrowserDataDir())
    if okFree then
        freeSpace = tostring(freeOrErr)
    end
    copied.storage_free_space = freeSpace
    return copied
end

local MUTABLE_SETTING_KEYS = {
    home_page = true,
    history_enabled = true,
    usage_guard_enabled = true,
    pause_inactive_applets = true,
    fullscreen_mode = true,
    default_monitor = true,
    browser_engine_level = true,
    default_bg_color = true,
    default_fg_color = true,
}

function persistedBrowserSettings()
    local copied = {}
    for key in pairs(MUTABLE_SETTING_KEYS) do
        copied[key] = tostring(browserSettings[key] or "")
    end
    return copied
end

function getBrowserSetting(key)
    local normalized = normalizeSettingKey(key)
    if normalized == "" then
        return nil
    end
    if normalized == "browser_data_dir" then
        return currentBrowserDataDir()
    end
    if normalized == "downloads_dir" then
        return currentDownloadsDir()
    end
    return browserSettings[normalized]
end

function parseBooleanSetting(value)
    local lowered = core.trim(tostring(value or "")):lower()
    if lowered == "true" or lowered == "1" or lowered == "yes" or lowered == "on" or lowered == "enabled" then
        return true
    end
    if lowered == "false" or lowered == "0" or lowered == "no" or lowered == "off" or lowered == "disabled" then
        return false
    end
    return nil
end

function normalizeLogLevel(value)
    if type(value) == "number" then
        local numeric = math.floor(value)
        if LOG_LEVEL_NAMES[numeric] then
            return numeric
        end
    end
    local lowered = core.trim(tostring(value or "")):lower()
    return LOG_LEVEL_ALIASES[lowered] or LogLevel.info
end

function normalizeLogPolicy(policyTable)
    local source = type(policyTable) == "table" and policyTable or {}
    local defaults = default.log or {}
    local normalized = {}

    local enabled = parseBooleanSetting(source.enabled)
    if enabled == nil then
        enabled = defaults.enabled == true
    end
    normalized.enabled = enabled

    local level = normalizeLogLevel(source.level or defaults.level)
    normalized.level = (LOG_LEVEL_NAMES[level] or "INFO"):lower()

    local maxFiles = tonumber(source.max_files)
    maxFiles = math.floor(maxFiles or tonumber(defaults.max_files) or 6)
    if maxFiles < 1 then
        maxFiles = 1
    elseif maxFiles > 64 then
        maxFiles = 64
    end
    normalized.max_files = maxFiles

    local maxFileSize = tonumber(source.max_file_size)
    maxFileSize = math.floor(maxFileSize or tonumber(defaults.max_file_size) or 131072)
    if maxFileSize < 1024 then
        maxFileSize = 1024
    elseif maxFileSize > 4194304 then
        maxFileSize = 4194304
    end
    normalized.max_file_size = maxFileSize

    local maxEntryLength = tonumber(source.max_entry_length)
    maxEntryLength = math.floor(maxEntryLength or tonumber(defaults.max_entry_length) or 2048)
    if maxEntryLength < 128 then
        maxEntryLength = 128
    elseif maxEntryLength > 65535 then
        maxEntryLength = 65535
    end
    normalized.max_entry_length = maxEntryLength

    return normalized
end

function normalizedBrowserPolicies(policiesTable)
    local source = type(policiesTable) == "table" and policiesTable or {}
    return {
        log = normalizeLogPolicy(source.log),
    }
end

function activeLogPath()
    return fs.combine(BROWSER_LOGS_DIR, "browser.log")
end

function rotatedLogPath(index)
    return fs.combine(BROWSER_LOGS_DIR, ("browser.%d.log"):format(math.floor(index or 1)))
end

function rotateBrowserLogsIfNeeded(policy)
    local activePath = activeLogPath()
    if not fs.exists(activePath) or fs.isDir(activePath) then
        return
    end

    local currentSize = tonumber(fs.getSize(activePath) or 0) or 0
    if currentSize < tonumber(policy.max_file_size or 0) then
        return
    end

    local maxFiles = math.max(1, math.floor(tonumber(policy.max_files) or 1))
    local maxRotated = math.max(0, maxFiles - 1)
    if maxRotated <= 0 then
        pcall(fs.delete, activePath)
        return
    end

    for idx = maxRotated, 1, -1 do
        local sourcePath = idx == 1 and activePath or rotatedLogPath(idx - 1)
        local destinationPath = rotatedLogPath(idx)
        if fs.exists(destinationPath) then
            pcall(fs.delete, destinationPath)
        end
        if fs.exists(sourcePath) and not fs.isDir(sourcePath) then
            pcall(fs.move, sourcePath, destinationPath)
        end
    end
end

function appendBrowserLogLine(line)
    local text = tostring(line or "")
    local policy = normalizedBrowserPolicies(browserPolicies).log
    browserPolicies.log = policy
    if not policy.enabled then
        return
    end
    if logWriteBusy then
        return
    end
    if not ensureDirExists(currentLogsDir(), "browser logs directory") then
        return
    end

    logWriteBusy = true
    rotateBrowserLogsIfNeeded(policy)
    local logPath = activeLogPath()
    local handle = fs.open(logPath, "a")
    if not handle then
        handle = fs.open(logPath, "w")
    end
    if handle then
        pcall(function()
            handle.writeLine(text)
        end)
        closeHandle(handle)
    end
    logWriteBusy = false
end

function log(message, level)
    local policy = normalizedBrowserPolicies(browserPolicies).log
    browserPolicies.log = policy
    local eventLevel = normalizeLogLevel(level)
    local threshold = normalizeLogLevel(policy.level)
    if eventLevel < threshold then
        return
    end

    local body = tostring(message or "")
    body = body:gsub("[\r\n\t]+", " ")
    if #body > policy.max_entry_length then
        body = body:sub(1, policy.max_entry_length)
    end

    local stamp = nil
    if os and type(os.date) == "function" then
        local okDate, rendered = pcall(os.date, "%Y-%m-%d %H:%M:%S")
        if okDate and rendered then
            stamp = tostring(rendered)
        end
    end
    if not stamp or stamp == "" then
        local clockValue = (os and type(os.clock) == "function") and os.clock() or 0
        stamp = ("clock %.3f"):format(clockValue)
    end

    local levelText = LOG_LEVEL_NAMES[eventLevel] or "INFO"
    appendBrowserLogLine("[" .. stamp .. "] [" .. levelText .. "] " .. body)
end

function setBooleanBrowserSetting(key, value)
    local parsed = parseBooleanSetting(value)
    if parsed == nil then
        return false, "Invalid " .. key .. " value (expected true/false)"
    end
    browserSettings[key] = parsed and "true" or "false"
    if persistBrowserState then
        persistBrowserState()
    end
    log("setting updated: " .. tostring(key) .. "=" .. tostring(browserSettings[key]), LogLevel.info)
    return true, nil
end

function setBrowserSetting(key, value)
    local normalized = normalizeSettingKey(key)
    if normalized == "" then
        return false, "Invalid setting key"
    end
    if value == nil then
        return false, "Missing setting value"
    end
    if normalized == "browser_data_dir" then
        return false, "browser_data_dir is fixed to " .. currentBrowserDataDir()
    end
    if normalized == "downloads_dir" then
        return false, "downloads_dir is fixed to " .. currentDownloadsDir()
    end
    if not MUTABLE_SETTING_KEYS[normalized] then
        return false, "Unsupported setting key"
    end
    if normalized == "history_enabled" then
        return setBooleanBrowserSetting(normalized, value)
    end
    if normalized == "usage_guard_enabled" then
        local parsed = parseBooleanSetting(value)
        if parsed == nil then
            return false, "Invalid usage_guard_enabled value (expected true/false)"
        end
        browserSettings[normalized] = parsed and "true" or "false"
        if persistBrowserState then
            persistBrowserState()
        end
        log("setting updated: " .. tostring(normalized) .. "=" .. tostring(browserSettings[normalized]), LogLevel.info)
        return true, nil
    end
    if normalized == "pause_inactive_applets" then
        local parsed = parseBooleanSetting(value)
        if parsed == nil then
            return false, "Invalid pause_inactive_applets value (expected true/false)"
        end
        browserSettings[normalized] = parsed and "true" or "false"
        if not parsed then
            if state and type(state.tabs) == "table" and flushPausedAppletQueue then
                for i = 1, #state.tabs do
                    flushPausedAppletQueue(state.tabs[i], 256)
                end
            end
        end
        if persistBrowserState then
            persistBrowserState()
        end
        log("setting updated: " .. tostring(normalized) .. "=" .. tostring(browserSettings[normalized]), LogLevel.info)
        return true, nil
    end
    if normalized == "fullscreen_mode" then
        local lowered = core.trim(tostring(value or "")):lower()
        if lowered ~= "normal" and lowered ~= "seamless" and lowered ~= "seemless" then
            return false, "Invalid fullscreen_mode value (expected normal/seamless)"
        end
        browserSettings[normalized] = normalizeFullscreenMode(lowered)
        if persistBrowserState then
            persistBrowserState()
        end
        log("setting updated: " .. tostring(normalized) .. "=" .. tostring(browserSettings[normalized]), LogLevel.info)
        return true, nil
    end
    if normalized == "default_monitor" then
        local choice = normalizeMonitorChoice(value)
        if choice ~= INTERNAL_MONITOR_ID and not monitorExists(choice) then
            return false, "Invalid default_monitor value (monitor not found: " .. tostring(choice) .. ")"
        end
        browserSettings[normalized] = choice
        displayManager.clearSessionOverride()
        if persistBrowserState then
            persistBrowserState()
        end
        refreshDisplayTarget()
        log("setting updated: " .. tostring(normalized) .. "=" .. tostring(browserSettings[normalized]), LogLevel.info)
        return true, nil
    end
    if normalized == "browser_engine_level" then
        local lowered = parseBrowserEngineLevel(value)
        if not lowered then
            return false, "Invalid browser_engine_level value (expected text_only/standard/advanced)"
        end
        browserSettings[normalized] = lowered
        if persistBrowserState then
            persistBrowserState()
        end
        log("setting updated: " .. tostring(normalized) .. "=" .. tostring(browserSettings[normalized]), LogLevel.info)
        return true, nil
    end
    if normalized == "default_bg_color" or normalized == "default_fg_color" then
        local colorName = parseSettingColorName(value)
        if not colorName then
            return false,
                "Invalid color value (expected one of: " .. SUPPORTED_SETTING_COLOR_ERROR_TEXT .. ")"
        end
        browserSettings[normalized] = colorName
        if persistBrowserState then
            persistBrowserState()
        end
        log("setting updated: " .. tostring(normalized) .. "=" .. tostring(browserSettings[normalized]), LogLevel.info)
        return true, nil
    end
    if normalized == "home_page" then
        local homePage = core.trim(tostring(value or ""))
        if homePage == "" then
            return false, "Missing home page value"
        end
        browserSettings[normalized] = homePage
    else
        browserSettings[normalized] = tostring(value)
    end
    if persistBrowserState then
        persistBrowserState()
    end
    log("setting updated: " .. tostring(normalized) .. "=" .. tostring(browserSettings[normalized]), LogLevel.info)
    return true, nil
end

function listBrowserFavorites()
    local copied = {}
    for i, item in ipairs(browserFavorites) do
        copied[i] = {
            url = tostring(item.url or ""),
            title = tostring(item.title or ""),
        }
    end
    return copied
end

function addBrowserFavorite(url, title)
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

function normalizeFavoriteUrl(url)
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

function findFavoriteIndex(url)
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

function isFavoriteUrl(url)
    local index = findFavoriteIndex(url)
    return index ~= nil
end

function canFavoriteUrl(url)
    local normalizedUrl = normalizeFavoriteUrl(url)
    if normalizedUrl == "" then
        return false
    end
    return not core.startsWith(normalizedUrl:lower(), "about:")
end

function removeBrowserFavorite(url)
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

local HISTORY_ENTRY_KEY_SEPARATOR = "\31"

function historyTimestampText()
    if os and type(os.date) == "function" then
        local okDateTime, dateTimeText = pcall(os.date, "%Y-%m-%d %H:%M:%S")
        if okDateTime and dateTimeText then
            return tostring(dateTimeText)
        end
    end
    return ("clock %.2fs"):format((os and type(os.clock) == "function") and os.clock() or 0)
end

function historyDayFromTimestamp(timestamp)
    local parsed = tostring(timestamp or ""):match("^(%d%d%d%d%-%d%d%-%d%d)")
    if parsed and parsed ~= "" then
        return parsed
    end
    return "Unknown"
end

function historyEntryKey(entry)
    return table.concat({
        tostring(entry.timestamp or ""),
        tostring(entry.url or ""),
        tostring(entry.title or ""),
    }, HISTORY_ENTRY_KEY_SEPARATOR)
end

function copyBrowserHistoryEntry(entry)
    local timestamp = tostring(entry.timestamp or "")
    return {
        key = historyEntryKey(entry),
        url = tostring(entry.url or ""),
        title = tostring(entry.title or ""),
        day = historyDayFromTimestamp(timestamp),
        timestamp = timestamp,
    }
end

function listBrowserHistory()
    local copied = {}
    for i, entry in ipairs(browserHistory) do
        copied[i] = copyBrowserHistoryEntry(entry)
    end
    return copied
end

function persistedBrowserHistoryEntries()
    local entries = {}
    for i, entry in ipairs(browserHistory) do
        entries[i] = {
            url = tostring(entry.url or ""),
            title = tostring(entry.title or ""),
            timestamp = tostring(entry.timestamp or ""),
        }
    end
    return entries
end

function removeBrowserHistoryEntry(entryToken)
    local token = core.trim(tostring(entryToken or ""))
    if token == "" then
        return false, "Missing history entry key"
    end

    local numericIndex = tonumber(token)
    if numericIndex then
        local index = math.floor(numericIndex)
        if index >= 1 and index <= #browserHistory then
            table.remove(browserHistory, index)
            if persistBrowserState then
                persistBrowserState()
            end
            return true, nil
        end
    end

    for i, entry in ipairs(browserHistory) do
        if historyEntryKey(entry) == token then
            table.remove(browserHistory, i)
            if persistBrowserState then
                persistBrowserState()
            end
            return true, nil
        end
    end
    return false, "History entry not found"
end

function clearBrowserHistoryDay(day)
    local wanted = core.trim(tostring(day or ""))
    if wanted == "" then
        return false, "Missing history day"
    end

    local kept = {}
    local removed = 0
    for _, entry in ipairs(browserHistory) do
        if historyDayFromTimestamp(entry.timestamp) == wanted then
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

function clearBrowserHistory()
    browserHistory = {}
    if persistBrowserState then
        persistBrowserState()
    end
    return true, nil
end

function shouldTrackNavigationInHistory(rawUrl)
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

function addBrowserHistory(url, title)
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

    local timestamp = historyTimestampText()
    local normalizedTitle = core.trim(tostring(title or ""))
    browserHistory[#browserHistory + 1] = {
        url = normalizedUrl,
        title = normalizedTitle,
        timestamp = timestamp,
    }

    if persistBrowserState then
        persistBrowserState()
    end
    return true
end

function applyDecodedConfig(decoded)
    if type(decoded.settings) == "table" then
        for key, rawValue in pairs(decoded.settings) do
            local normalized = normalizeSettingKey(key)
            if MUTABLE_SETTING_KEYS[normalized] then
                if normalized == "fullscreen_mode" then
                    browserSettings[normalized] = normalizeFullscreenMode(rawValue)
                elseif normalized == "default_monitor" then
                    browserSettings[normalized] = normalizeMonitorChoice(rawValue)
                elseif normalized == "browser_engine_level" then
                    browserSettings[normalized] = normalizeBrowserEngineLevel(rawValue)
                elseif normalized == "default_bg_color" then
                    browserSettings[normalized] = normalizeSettingColorName(rawValue, "black")
                elseif normalized == "default_fg_color" then
                    browserSettings[normalized] = normalizeSettingColorName(rawValue, "white")
                elseif normalized == "home_page" then
                    local homePage = core.trim(tostring(rawValue or ""))
                    if homePage ~= "" then
                        browserSettings[normalized] = homePage
                    end
                elseif normalized == "history_enabled"
                    or normalized == "usage_guard_enabled"
                    or normalized == "pause_inactive_applets" then
                    local parsed = parseBooleanSetting(rawValue)
                    if parsed ~= nil then
                        browserSettings[normalized] = parsed and "true" or "false"
                    end
                end
            end
        end
    end

    if type(decoded.policies) == "table" then
        browserPolicies = normalizedBrowserPolicies(decoded.policies)
    end

    browserSettings.fullscreen_mode = normalizeFullscreenMode(browserSettings.fullscreen_mode)
    browserSettings.default_monitor = normalizeMonitorChoice(browserSettings.default_monitor)
    browserSettings.browser_engine_level = normalizeBrowserEngineLevel(browserSettings.browser_engine_level)
    browserSettings.default_bg_color = normalizeSettingColorName(browserSettings.default_bg_color, "black")
    browserSettings.default_fg_color = normalizeSettingColorName(browserSettings.default_fg_color, "white")
    browserPolicies = normalizedBrowserPolicies(browserPolicies)

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
end

function applyDecodedHistory(historyTable)
    browserHistory = {}
    if type(historyTable) == "table" then
        for _, item in ipairs(historyTable) do
            local url = core.trim(tostring(item and item.url or ""))
            if url ~= "" then
                local title = core.trim(tostring(item.title or ""))
                local timestamp = core.trim(tostring(item.timestamp or ""))
                if timestamp == "" then
                    local legacyDay = core.trim(tostring(item.day or ""))
                    if legacyDay ~= "" and legacyDay:match("^%d%d%d%d%-%d%d%-%d%d$") then
                        timestamp = legacyDay .. " 00:00:00"
                    else
                        timestamp = historyTimestampText()
                    end
                end

                browserHistory[#browserHistory + 1] = {
                    url = url,
                    title = title,
                    timestamp = timestamp,
                }
            end
        end
    end
end

function readSerializedTable(path)
    if not fs.exists(path) then
        return nil, "File not found"
    end
    local payload, readErr = readTextFile(path)
    if payload == nil then
        return nil, tostring(readErr or "Could not read file")
    end
    if payload == "" then
        return nil, "Saved data is empty"
    end

    local okParse, decoded = pcall(textutils.unserialize, payload)
    if not okParse or type(decoded) ~= "table" then
        return nil, "Saved data is invalid"
    end
    return decoded, nil
end

function loadBrowserState()
    if not (fs and fs.exists and fs.open) then
        return false, "Filesystem unavailable"
    end
    if not (textutils and type(textutils.unserialize) == "function") then
        return false, "Serializer unavailable"
    end

    local loadedAny = false

    local configDecoded = readSerializedTable(browserConfigPath())
    if type(configDecoded) == "table" then
        applyDecodedConfig(configDecoded)
        loadedAny = true
        log("config loaded from " .. tostring(browserConfigPath()), LogLevel.info)
    end

    local historyDecoded = readSerializedTable(browserHistoryPath())
    if type(historyDecoded) == "table" then
        applyDecodedHistory(type(historyDecoded.entries) == "table" and historyDecoded.entries or historyDecoded.history)
        loadedAny = true
        log("history loaded from " .. tostring(browserHistoryPath()), LogLevel.info)
    else
        applyDecodedHistory({})
    end

    if loadedAny then
        return true, nil
    end

    local legacyDecoded, legacyErr = readSerializedTable(legacyBrowserStatePath())
    if not legacyDecoded then
        log("browser state load failed: " .. tostring(legacyErr or "No saved state"), LogLevel.warn)
        return false, tostring(legacyErr or "No saved state")
    end

    applyDecodedConfig(legacyDecoded)
    applyDecodedHistory(legacyDecoded.history)
    log("legacy browser state loaded from " .. tostring(legacyBrowserStatePath()), LogLevel.warn)
    return true, nil
end

persistBrowserState = function(_forceWrite)
    if not (fs and fs.open) then
        return false, "Filesystem unavailable"
    end
    if not (textutils and type(textutils.serialize) == "function") then
        return false, "Serializer unavailable"
    end
    local okStorage, storageErr = ensureStoragePaths()
    if not okStorage then
        return false, tostring(storageErr or "Could not prepare storage paths")
    end

    local configSnapshot = {
        version = 3,
        settings = persistedBrowserSettings(),
        policies = normalizedBrowserPolicies(browserPolicies),
        favorites = listBrowserFavorites(),
    }
    local historySnapshot = {
        version = 2,
        entries = persistedBrowserHistoryEntries(),
    }
    local configEncoded = textutils.serialize(configSnapshot)
    local historyEncoded = textutils.serialize(historySnapshot)
    if not configEncoded or not historyEncoded then
        return false, "Failed to encode state"
    end

    local okConfigWrite, configWriteErr = writeTextFile(browserConfigPath(), configEncoded)
    if not okConfigWrite then
        storageReady = false
        lastStorageError = tostring(configWriteErr or "Could not write config file")
        log(lastStorageError, LogLevel.error)
        return false, lastStorageError
    end
    local okHistoryWrite, historyWriteErr = writeTextFile(browserHistoryPath(), historyEncoded)
    if not okHistoryWrite then
        storageReady = false
        lastStorageError = tostring(historyWriteErr or "Could not write history file")
        log(lastStorageError, LogLevel.error)
        return false, lastStorageError
    end
    storageReady = true
    lastStorageError = nil
    return true, nil
end

local initialStorageReady = ensureStoragePaths()
if initialStorageReady then
    loadBrowserState()
    if not fs.exists(browserConfigPath()) or not fs.exists(browserHistoryPath()) then
        persistBrowserState(true)
        log("initialized browser state store", LogLevel.info)
    end
else
    storageReady = false
    if not lastStorageError or lastStorageError == "" then
        lastStorageError = "Storage initialization failed"
    end
    log(lastStorageError, LogLevel.error)
end
browserSettings.default_monitor = normalizeMonitorChoice(browserSettings.default_monitor)
browserSettings.browser_engine_level = normalizeBrowserEngineLevel(browserSettings.browser_engine_level)
browserSettings.default_bg_color = normalizeSettingColorName(browserSettings.default_bg_color, "black")
browserSettings.default_fg_color = normalizeSettingColorName(browserSettings.default_fg_color, "white")
browserPolicies = normalizedBrowserPolicies(browserPolicies)

local network = createNetwork(core, {
    aboutPagesDir = fs.combine(SCRIPT_DIR, "about-pages"),
    aboutApi = {
        appTitle = APP_TITLE,
        appVersion = APP_VERSION,
        appIcon = APP_ICON,
        getBrowserDataDir = currentBrowserDataDir,
        listSettings = listBrowserSettings,
        getSetting = getBrowserSetting,
        setSetting = setBrowserSetting,
        listFavorites = listBrowserFavorites,
        listHistory = listBrowserHistory,
        removeHistoryEntry = removeBrowserHistoryEntry,
        clearHistoryDay = clearBrowserHistoryDay,
        clearHistory = clearBrowserHistory,
        listMonitors = listMonitorTargets,
        getActiveMonitor = function()
            return displayManager.getRuntimeDisplayTarget() or INTERNAL_MONITOR_ID
        end,
        getMonitorOverride = function()
            return displayManager.getStartupMonitorOverride() or ""
        end,
    },
})
local html = createHtml(core)
local content = createContent({
    core = core,
    html = html,
    network = network,
    getEngineLevel = function()
        return normalizeBrowserEngineLevel(browserSettings.browser_engine_level)
    end,
    getDefaultBackgroundColor = function()
        return normalizeSettingColorName(browserSettings.default_bg_color, "black")
    end,
    getDefaultForegroundColor = function()
        return normalizeSettingColorName(browserSettings.default_fg_color, "white")
    end,
    getDefaultTextColor = function()
        return normalizeSettingColorName(browserSettings.default_fg_color, "white")
    end,
})
local sandbox = createSandbox({
    core = core,
    getVfsRoot = currentVfsRoot,
})
local printing = createPrinting()

local clamp = core.clamp
local startsWith = core.startsWith
local trim = core.trim
local escapeHtml = core.escapeHtml
local normalizeInputUrl = core.normalizeInputUrl
local getHeader = core.getHeader
local formControls = createFormControls({
    clamp = clamp,
    trim = trim,
})

