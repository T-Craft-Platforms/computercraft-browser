APP_TITLE = "CC Browser"
APP_VERSION = "0.1.0"
APP_ICON = "[CC]"

function normalizeScriptDir(path)
    local normalized = fs.combine(tostring(path or ""), "")
    if normalized ~= "/" and #normalized > 1 and normalized:sub(-1) == "/" then
        normalized = normalized:sub(1, -2)
    end
    if normalized == "" then
        normalized = "."
    end
    return normalized
end

function looksLikeBrowserRoot(path)
    local root = normalizeScriptDir(path)
    local corePath = fs.combine(root, "lib/core.lua")
    local networkPath = fs.combine(root, "lib/network.lua")
    local aboutPath = fs.combine(root, "about-pages")
    return fs.exists(corePath) and not fs.isDir(corePath)
        and fs.exists(networkPath) and not fs.isDir(networkPath)
        and fs.exists(aboutPath) and fs.isDir(aboutPath)
end

function getScriptDir()
    local candidates = {}
    local function push(path)
        if not path or path == "" then
            return
        end
        candidates[#candidates + 1] = normalizeScriptDir(path)
    end

    if type(CC_BROWSER_BASE_DIR) == "string" and CC_BROWSER_BASE_DIR ~= "" then
        push(CC_BROWSER_BASE_DIR)
    end

    if debug and type(debug.getinfo) == "function" then
        local okInfo, info = pcall(debug.getinfo, 1, "S")
        if okInfo and type(info) == "table" and type(info.source) == "string" then
            local source = tostring(info.source or "")
            if source:sub(1, 1) == "@" then
                push(fs.getDir(source:sub(2)))
            end
        end
    end

    if shell and shell.getRunningProgram and fs and fs.getDir then
        local running = shell.getRunningProgram()
        if running and running ~= "" then
            push(fs.getDir(running))
            if shell and type(shell.resolve) == "function" then
                local okResolve, resolved = pcall(shell.resolve, running)
                if okResolve and resolved and resolved ~= "" then
                    push(fs.getDir(resolved))
                end
            end
        end
    end

    if shell and type(shell.dir) == "function" then
        push(shell.dir())
    end
    push(".")
    push("/")

    local seen = {}
    for i = 1, #candidates do
        local candidate = candidates[i]
        if not seen[candidate] then
            seen[candidate] = true
            if looksLikeBrowserRoot(candidate) then
                return candidate
            end
        end
    end

    if shell and type(shell.dir) == "function" then
        return normalizeScriptDir(shell.dir())
    end
    return "."
end

SCRIPT_DIR = getScriptDir()

function loadModule(relativePath)
    return dofile(fs.combine(SCRIPT_DIR, relativePath))
end

core = loadModule("lib/core.lua")
createNetwork = loadModule("lib/network.lua")
createHtml = loadModule("lib/html.lua")
createContent = loadModule("lib/content.lua")
createUi = loadModule("ui/view.lua")
createSandbox = loadModule("lib/sandbox.lua")
createPrinting = loadModule("lib/printing.lua")
createFormControls = loadModule("lib/form-controls.lua")
local FIXED_BROWSER_DATA_DIR_CANDIDATES = {
    ".ccbrowser",
    "browser-data",
}

function pickBrowserDataDir()
    local function appendUnique(paths, seen, path)
        local normalized = normalizeScriptDir(path)
        if normalized == "" or seen[normalized] then
            return
        end
        seen[normalized] = true
        paths[#paths + 1] = normalized
    end

    local function callHandleWrite(handle, payload)
        local okWrite = pcall(function()
            handle.write(payload)
        end)
        if not okWrite then
            okWrite = pcall(function()
                handle:write(payload)
            end)
        end
        return okWrite
    end

    local function callHandleClose(handle)
        local okClose = pcall(function()
            handle.close()
        end)
        if not okClose then
            okClose = pcall(function()
                handle:close()
            end)
        end
        return okClose
    end

    local function buildCandidates()
        local candidates = {}
        local seen = {}
        for _, relativePath in ipairs(FIXED_BROWSER_DATA_DIR_CANDIDATES) do
            appendUnique(candidates, seen, fs.combine(SCRIPT_DIR, relativePath))
        end
        appendUnique(candidates, seen, "/.ccbrowser")
        appendUnique(candidates, seen, "/browser-data")
        return candidates
    end

    local function canWriteInDirectory(path)
        if not path or path == "" then
            return false
        end
        if fs.exists(path) and not fs.isDir(path) then
            return false
        end
        if not fs.exists(path) then
            local okMake = pcall(fs.makeDir, path)
            if not okMake or not fs.exists(path) or not fs.isDir(path) then
                return false
            end
        end

        local probePath = fs.combine(path, ".ccbrowser-write-probe")
        local probeHandle = fs.open(probePath, "w")
        if not probeHandle then
            return false
        end
        local okWrite = callHandleWrite(probeHandle, "ok")
        local okClose = callHandleClose(probeHandle)
        pcall(fs.delete, probePath)
        return okWrite and okClose
    end

    local candidates = buildCandidates()
    for _, candidate in ipairs(candidates) do
        if canWriteInDirectory(candidate) then
            return candidate
        end
    end
    return candidates[1] or "/.ccbrowser"
end

local BROWSER_DATA_DIR = pickBrowserDataDir()
local BROWSER_SETTINGS_DIR = fs.combine(BROWSER_DATA_DIR, "config")
local BROWSER_DOWNLOADS_DIR = fs.combine(BROWSER_DATA_DIR, "downloads")
local BROWSER_VFS_DIR = fs.combine(BROWSER_DATA_DIR, "vfs")
local BROWSER_LOGS_DIR = fs.combine(BROWSER_DATA_DIR, "logs")
local BROWSER_CONFIG_PATH = fs.combine(BROWSER_SETTINGS_DIR, "config.tbl")
local BROWSER_HISTORY_PATH = fs.combine(BROWSER_SETTINGS_DIR, "history.tbl")
local BROWSER_LEGACY_STATE_PATH = fs.combine(BROWSER_SETTINGS_DIR, "browser-state.tbl")

local browserSettings = {
    home_page = "about:home",
    history_enabled = "true",
    usage_guard_enabled = "true",
    pause_inactive_applets = "true",
    fullscreen_mode = "normal",
    default_monitor = "internal",
    browser_engine_level = "standard",
    default_bg_color = "black",
    default_fg_color = "white",
}
local default = {
    log = {
        enabled = true,
        level = "info",
        max_files = 6,
        max_file_size = 131072,
        max_entry_length = 2048,
    },
}
local browserPolicies = {
    log = {
        enabled = default.log.enabled,
        level = default.log.level,
        max_files = default.log.max_files,
        max_file_size = default.log.max_file_size,
        max_entry_length = default.log.max_entry_length,
    },
}
local browserFavorites = {}
local browserHistory = {}
local persistBrowserState
local state
local flushPausedAppletQueue
local storageReady = false
local lastStorageError = nil
local logWriteBusy = false

LogLevel = {
    trace = 10,
    debug = 20,
    info = 30,
    warn = 40,
    error = 50,
    TRACE = 10,
    DEBUG = 20,
    INFO = 30,
    WARN = 40,
    ERROR = 50,
}

local LOG_LEVEL_NAMES = {
    [10] = "TRACE",
    [20] = "DEBUG",
    [30] = "INFO",
    [40] = "WARN",
    [50] = "ERROR",
}

local LOG_LEVEL_ALIASES = {
    trace = 10,
    debug = 20,
    info = 30,
    warn = 40,
    warning = 40,
    error = 50,
}

function settingEnabledRaw(name, defaultEnabled)
    local defaultText = defaultEnabled and "true" or "false"
    local raw = core.trim(tostring(browserSettings[name] or defaultText)):lower()
    return not (raw == "false" or raw == "0" or raw == "no" or raw == "off" or raw == "disabled")
end

function normalizeSettingKey(key)
    local normalized = tostring(key or ""):lower()
    normalized = normalized:gsub("[^%w_%-]", "_")
    normalized = normalized:gsub("_+", "_")
    if normalized == "fullscreen" then
        return "fullscreen_mode"
    end
    if normalized == "monitor" or normalized == "display_monitor" or normalized == "default_display_monitor" then
        return "default_monitor"
    end
    if normalized == "default_text_color" or normalized == "default_foreground_color" then
        return "default_fg_color"
    end
    if normalized == "config_dir" or normalized == "settings_path" or normalized == "settings_dir" then
        return "browser_data_dir"
    end
    if normalized == "download_path" or normalized == "default_download_path"
        or normalized == "download_location" or normalized == "default_download_location" then
        return "downloads_dir"
    end
    return normalized
end

function normalizeFullscreenMode(value)
    local lowered = core.trim(tostring(value or "")):lower()
    if lowered == "seamless" or lowered == "seemless" then
        return "seamless"
    end
    return "normal"
end

function parseBrowserEngineLevel(value)
    local lowered = core.trim(tostring(value or "")):lower()
    lowered = lowered:gsub("%-", "_")
    if lowered == "text" or lowered == "textonly" then
        lowered = "text_only"
    end
    if lowered == "lite" then
        lowered = "standard"
    end
    if lowered == "text_only" or lowered == "standard" or lowered == "advanced" then
        return lowered
    end
    return nil
end

function normalizeBrowserEngineLevel(value)
    return parseBrowserEngineLevel(value) or "standard"
end

local SUPPORTED_SETTING_COLOR_VALUES = {
    white = colors.white,
    orange = colors.orange,
    magenta = colors.magenta,
    lightblue = colors.lightBlue,
    yellow = colors.yellow,
    lime = colors.lime,
    pink = colors.pink,
    gray = colors.gray,
    lightgray = colors.lightGray,
    cyan = colors.cyan,
    purple = colors.purple,
    blue = colors.blue,
    brown = colors.brown,
    green = colors.green,
    red = colors.red,
    black = colors.black,
}

local SUPPORTED_SETTING_COLOR_ALIASES = {
    white = "white",
    orange = "orange",
    magenta = "magenta",
    lightblue = "lightblue",
    light_blue = "lightblue",
    yellow = "yellow",
    lime = "lime",
    pink = "pink",
    gray = "gray",
    grey = "gray",
    lightgray = "lightgray",
    lightgrey = "lightgray",
    light_gray = "lightgray",
    light_grey = "lightgray",
    cyan = "cyan",
    purple = "purple",
    blue = "blue",
    brown = "brown",
    green = "green",
    red = "red",
    black = "black",
}

local COLOR_VALUE_TO_SETTING_NAME = {}
for name, colorValue in pairs(SUPPORTED_SETTING_COLOR_VALUES) do
    COLOR_VALUE_TO_SETTING_NAME[colorValue] = name
end

local SUPPORTED_SETTING_COLOR_ERROR_TEXT = table.concat({
    "white",
    "orange",
    "magenta",
    "lightblue",
    "yellow",
    "lime",
    "pink",
    "gray",
    "lightgray",
    "cyan",
    "purple",
    "blue",
    "brown",
    "green",
    "red",
    "black",
}, "/")

function parseSettingColorName(value)
    local raw = core.trim(tostring(value or "")):lower()
    if raw == "" then
        return nil
    end
    local compact = raw:gsub("%s+", ""):gsub("%-", "_")
    local aliased = SUPPORTED_SETTING_COLOR_ALIASES[compact]
    if aliased then
        return aliased
    end
    if type(core.parseCssColor) == "function" then
        local parsedValue = core.parseCssColor(raw, nil)
        if parsedValue and COLOR_VALUE_TO_SETTING_NAME[parsedValue] then
            return COLOR_VALUE_TO_SETTING_NAME[parsedValue]
        end
    end
    return nil
end

function normalizeSettingColorName(value, fallbackName)
    local parsed = parseSettingColorName(value)
    if parsed then
        return parsed
    end
    return fallbackName
end

function settingColorValue(settingName, fallbackName)
    local colorName = normalizeSettingColorName(browserSettings[settingName], fallbackName)
    return SUPPORTED_SETTING_COLOR_VALUES[colorName] or SUPPORTED_SETTING_COLOR_VALUES[fallbackName] or colors.white
end

function currentDefaultBackgroundColorValue()
    return settingColorValue("default_bg_color", "black")
end

function currentDefaultForegroundColorValue(background)
    local bg = background or currentDefaultBackgroundColorValue()
    local fg = settingColorValue("default_fg_color", "white")
    if fg == bg then
        if bg == colors.white or bg == colors.yellow or bg == colors.orange or bg == colors.lightGray then
            return colors.black
        end
        return colors.white
    end
    return fg
end

function currentBrowserDataDir()
    return BROWSER_DATA_DIR
end

function currentSettingsDir()
    return BROWSER_SETTINGS_DIR
end

function currentDownloadsDir()
    return BROWSER_DOWNLOADS_DIR
end

function currentVfsRoot()
    return BROWSER_VFS_DIR
end

local INTERNAL_MONITOR_ID = "internal"
local INTERNAL_MONITOR_LABEL = "Internal Monitor"
local NATIVE_TERM = (term and type(term.native) == "function" and term.native()) or (term and term.current and term.current()) or term
local runtimeDisplayTarget = INTERNAL_MONITOR_ID
local runtimeDisplayMonitorPeripheral = nil
local startupMonitorOverride = nil
local sessionMonitorOverride = nil

function normalizeMonitorChoice(value)
    local raw = core.trim(tostring(value or ""))
    local lowered = raw:lower()
    if lowered == "" or lowered == "internal" or lowered == "computer" or lowered == "terminal" then
        return INTERNAL_MONITOR_ID
    end
    return raw
end

function attachedMonitorNames()
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

function monitorExists(name)
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

function listMonitorTargets()
    local targets = {
        { value = INTERNAL_MONITOR_ID, label = INTERNAL_MONITOR_LABEL },
    }
    for _, name in ipairs(attachedMonitorNames()) do
        targets[#targets + 1] = { value = name, label = name }
    end
    return targets
end

function monitorSurface(choice)
    local normalized = normalizeMonitorChoice(choice)
    if normalized == INTERNAL_MONITOR_ID then
        return NATIVE_TERM
    end
    if peripheral and type(peripheral.wrap) == "function" then
        return peripheral.wrap(normalized)
    end
    return nil
end

function runOnSurface(surface, fn)
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

function clearSurface(choice, background, foreground)
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

function applyDisplayTarget(choice)
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

function refreshDisplayTarget()
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
        if persistBrowserState then
            persistBrowserState()
        end
    end
    return false, "Display target unavailable; switched to internal monitor."
end

function currentLogsDir()
    return BROWSER_LOGS_DIR
end

function browserConfigPath()
    return BROWSER_CONFIG_PATH
end

function browserHistoryPath()
    return BROWSER_HISTORY_PATH
end

function legacyBrowserStatePath()
    return BROWSER_LEGACY_STATE_PATH
end

function pathReadOnly(path)
    if not (fs and type(fs.isReadOnly) == "function") then
        return false
    end
    local okReadOnly, readOnly = pcall(fs.isReadOnly, path)
    if not okReadOnly then
        return false
    end
    return readOnly and true or false
end

function ensureDirExists(path, label)
    local name = tostring(label or "directory")
    if not path or path == "" then
        return false, name .. ": empty path"
    end
    if fs.exists(path) then
        if not fs.isDir(path) then
            return false, name .. ": exists as file (" .. tostring(path) .. ")"
        end
        if pathReadOnly(path) then
            return false, name .. ": read-only (" .. tostring(path) .. ")"
        end
        return true, nil
    end

    local parent = fs.getDir(path)
    if parent and parent ~= "" and fs.exists(parent) and pathReadOnly(parent) then
        return false, name .. ": parent is read-only (" .. tostring(parent) .. ")"
    end

    local okMake, makeErr = pcall(fs.makeDir, path)
    if not okMake then
        return false, name .. ": makeDir failed (" .. tostring(makeErr) .. ")"
    end
    if not fs.exists(path) or not fs.isDir(path) then
        return false, name .. ": makeDir did not create directory (" .. tostring(path) .. ")"
    end
    if pathReadOnly(path) then
        return false, name .. ": created but read-only (" .. tostring(path) .. ")"
    end
    return true, nil
end

function ensureStoragePaths()
    local okData, dataErr = ensureDirExists(currentBrowserDataDir(), "browser data directory")
    if not okData then
        storageReady = false
        lastStorageError = tostring(dataErr or "Could not prepare browser data directory")
        log(lastStorageError, LogLevel.warn)
        return false, lastStorageError
    end

    local okSettings, settingsErr = ensureDirExists(currentSettingsDir(), "browser settings directory")
    if not okSettings then
        storageReady = false
        lastStorageError = tostring(settingsErr or "Could not prepare browser settings directory")
        log(lastStorageError, LogLevel.warn)
        return false, lastStorageError
    end

    local okDownloads, downloadsErr = ensureDirExists(currentDownloadsDir(), "browser downloads directory")
    if not okDownloads then
        storageReady = false
        lastStorageError = tostring(downloadsErr or "Could not prepare browser downloads directory")
        log(lastStorageError, LogLevel.warn)
        return false, lastStorageError
    end

    local okVfs, vfsErr = ensureDirExists(currentVfsRoot(), "browser applet directory")
    if not okVfs then
        storageReady = false
        lastStorageError = tostring(vfsErr or "Could not prepare browser applet directory")
        log(lastStorageError, LogLevel.warn)
        return false, lastStorageError
    end

    local okLogs, logsErr = ensureDirExists(currentLogsDir(), "browser logs directory")
    if not okLogs then
        storageReady = false
        lastStorageError = tostring(logsErr or "Could not prepare browser logs directory")
        log(lastStorageError, LogLevel.warn)
        return false, lastStorageError
    end

    storageReady = true
    lastStorageError = nil
    return true, nil
end

function readHandleAll(handle)
    local okRead, payloadOrErr = pcall(function()
        return handle.readAll() or ""
    end)
    if not okRead then
        okRead, payloadOrErr = pcall(function()
            return handle:readAll() or ""
        end)
    end
    if not okRead then
        return nil, tostring(payloadOrErr or "Failed reading file")
    end
    return tostring(payloadOrErr or ""), nil
end

function writeHandleAll(handle, payload)
    local text = tostring(payload or "")
    local okWrite, writeErr = pcall(function()
        handle.write(text)
    end)
    if not okWrite then
        okWrite, writeErr = pcall(function()
            handle:write(text)
        end)
    end
    if not okWrite then
        return false, tostring(writeErr or "Failed writing file")
    end
    return true, nil
end

function closeHandle(handle)
    local okClose = pcall(function()
        handle.close()
    end)
    if not okClose then
        okClose = pcall(function()
            handle:close()
        end)
    end
    return okClose
end

function readTextFile(path)
    if not (fs and fs.exists and fs.open) then
        return nil, "Filesystem unavailable"
    end
    if not fs.exists(path) then
        log("readTextFile missing: " .. tostring(path), LogLevel.warn)
        return nil, "File not found"
    end

    local handle = fs.open(path, "r")
    if not handle then
        log("readTextFile open failed: " .. tostring(path), LogLevel.error)
        return nil, "Could not open file"
    end

    local payload, readErr = readHandleAll(handle)
    if not closeHandle(handle) then
        log("readTextFile close failed: " .. tostring(path), LogLevel.warn)
        return nil, "Could not close file"
    end

    if payload == nil then
        log("readTextFile failed: " .. tostring(path) .. " (" .. tostring(readErr or "read error") .. ")", LogLevel.error)
        return nil, tostring(readErr or "Failed reading file")
    end
    return payload, nil
end

function writeTextFile(path, payload)
    if not (fs and fs.open) then
        return false, "Filesystem unavailable"
    end
    local target = tostring(path or "")
    if core.trim(target) == "" then
        return false, "Invalid target path"
    end

    local targetDir = fs.getDir(target)
    if targetDir and targetDir ~= "" then
        local okDir, dirErr = ensureDirExists(targetDir, "target directory")
        if not okDir then
            return false, tostring(dirErr or "Could not prepare directory")
        end
    end

    local handle = fs.open(target, "w")
    if not handle then
        log("writeTextFile open failed: " .. tostring(target), LogLevel.error)
        return false, "Could not open file for writing"
    end

    local okWrite, writeErr = writeHandleAll(handle, payload)
    if not closeHandle(handle) then
        log("writeTextFile close failed: " .. tostring(target), LogLevel.warn)
        return false, "Could not close file"
    end

    if not okWrite then
        log("writeTextFile failed: " .. tostring(target) .. " (" .. tostring(writeErr or "write error") .. ")", LogLevel.error)
        return false, tostring(writeErr or "Failed writing file")
    end
    return true, nil
end

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
    copied.active_monitor = tostring(runtimeDisplayTarget or INTERNAL_MONITOR_ID)
    copied.available_monitors = table.concat(attachedMonitorNames(), ",")
    copied.monitor_override = tostring(startupMonitorOverride or "")
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
        sessionMonitorOverride = nil
        if persistBrowserState then
            persistBrowserState()
        end
        if not startupMonitorOverride then
            refreshDisplayTarget()
        end
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
            return runtimeDisplayTarget or INTERNAL_MONITOR_ID
        end,
        getMonitorOverride = function()
            return startupMonitorOverride or ""
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

function activeTab()
    if #state.tabs < 1 then
        state.tabs[1] = createTab(homePageUrl())
        state.activeTab = 1
    end
    state.activeTab = clamp(state.activeTab, 1, #state.tabs)
    return state.tabs[state.activeTab]
end

function syncAppletWindowVisibility()
    local tabCount = #state.tabs
    if tabCount < 1 then
        return
    end

    local activeIndex = clamp(state.activeTab, 1, tabCount)
    local showActive = not state.menuOpen and not state.modal.open

    for index = 1, tabCount do
        local tab = state.tabs[index]
        local applet = tab and tab.applet or nil
        local windowHandle = applet and applet.window or nil
        if windowHandle and windowHandle.setVisible then
            local shouldShow = showActive and index == activeIndex and applet.running == true
            pcall(windowHandle.setVisible, shouldShow and true or false)
        end
    end
end

function clearUrlSelection(tab)
    local target = tab or activeTab()
    target.urlSelStart = nil
    target.urlSelEnd = nil
end

function getUrlSelection(tab)
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

function getSelectedUrlText(tab)
    local target = tab or activeTab()
    local startPos, endPos = getUrlSelection(target)
    if not startPos then
        return ""
    end
    return target.urlInput:sub(startPos, endPos - 1)
end

function deleteUrlSelection(tab)
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

function clearPageSelection(tab)
    local target = tab or activeTab()
    target.pageSelection = nil
end

function bumpRenderRevision(tab)
    local target = tab or activeTab()
    target.renderRevision = (target.renderRevision or 0) + 1
end

function pageLineCount(tab)
    local target = tab or activeTab()
    local count = tonumber(target.pageContentHeight)
    if not count then
        count = #target.pageLines
    end
    return math.max(1, math.floor(count or 1))
end

function normalizedPageSelection(tab)
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

function pageSelectionContains(selection, lineIndex, column)
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

function setPageSelection(tab, startLine, startCol, endLine, endCol)
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

function selectAllPageText(tab)
    local target = tab or activeTab()
    local totalLines = pageLineCount(target)
    if totalLines < 1 then
        clearPageSelection(target)
        return
    end

    local width = math.max(1, target.viewportWidth or 1)
    setPageSelection(target, 1, 1, totalLines, width)
end

function getSelectedPageText(tab)
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

function pageHeight()
    local _, h = term.getSize()
    return math.max(1, h - effectiveTopBarRows())
end

function pageContentWidth(tab)
    local target = tab or activeTab()
    local w, _ = term.getSize()
    return clamp(target.viewportWidth or w, 1, w)
end

function pageOverflowY(tab)
    local target = tab or activeTab()
    local mode = target and target.document and target.document.pageOverflowY or "visible"
    if mode == "hidden" or mode == "scroll" or mode == "auto" then
        return mode
    end
    return "visible"
end

function maxScroll(tab)
    local target = tab or activeTab()
    if pageOverflowY(target) == "hidden" then
        return 0
    end
    return math.max(0, pageLineCount(target) - pageHeight())
end

function setScroll(value, tab)
    local target = tab or activeTab()
    target.scroll = clamp(value, 0, maxScroll(target))
end

function canGoBack(tab)
    local target = tab or activeTab()
    return target.historyIndex > 1
end

function canGoForward(tab)
    local target = tab or activeTab()
    return target.historyIndex > 0 and target.historyIndex < #target.history
end

function pushHistory(tab, url)
    local target = tab or activeTab()
    for i = #target.history, target.historyIndex + 1, -1 do
        target.history[i] = nil
    end
    table.insert(target.history, url)
    target.historyIndex = #target.history
end

function collapseExpandedTab()
    state.expandedTabIndex = nil
end

function toggleExpandedTab(index)
    if state.expandedTabIndex == index then
        collapseExpandedTab()
    else
        state.expandedTabIndex = index
    end
end

function activateTab(index)
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
    syncAppletWindowVisibility()
    if flushPausedAppletQueue then
        flushPausedAppletQueue(activeTab(), PAUSED_APPLET_EVENT_MAX)
    end
end

function moveTab(fromIndex, toIndex)
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

function newTab(initialUrl)
    local tab = createTab(initialUrl or homePageUrl())
    table.insert(state.tabs, tab)
    collapseExpandedTab()
    activateTab(#state.tabs)
    return tab
end

function closeTab(index)
    local targetIndex = clamp(index or state.activeTab, 1, #state.tabs)
    if #state.tabs <= 1 then
        local tab = activeTab()
        if stopAppletForTab then
            stopAppletForTab(tab, true)
        end
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
        tab.pageDefaultBackground = tab.document.defaultBackground or currentDefaultBackgroundColorValue()
        tab.pageDefaultForeground = tab.document.defaultForeground
            or currentDefaultForegroundColorValue(tab.pageDefaultBackground)
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
        tab.settingsStickyStatus = nil
        tab.pendingApplet = nil
        tab.applet = nil
        state.tabDrag = nil
        state.scrollbarDrag = nil
        state.menuOpen = false
        collapseExpandedTab()
        return
    end

    local removedTab = state.tabs[targetIndex]
    if removedTab and stopAppletForTab then
        stopAppletForTab(removedTab, true)
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

function closeActiveTab()
    closeTab(state.activeTab)
end

function cycleTabs(direction)
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
local draw
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
        local helper = "Use the buttons below from this terminal."
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
        controls.switchButton = drawButton(switchY, "Switch To Internal (One-Time)", colors.black, colors.lime)
        controls.exitButton = drawButton(exitY, "Exit Browser", colors.white, colors.red)
        controls.visible = true
    end)
end

function handleNativeMonitorControlClick(button, x, y)
    local controls = state.monitorControls
    if runtimeDisplayTarget == INTERNAL_MONITOR_ID or not controls or not controls.visible then
        return false
    end
    if button ~= 1 then
        return true
    end
    if hitRegion(x, y, controls.switchButton) then
        sessionMonitorOverride = INTERNAL_MONITOR_ID
        local okDisplay, displayErr = refreshDisplayTarget()
        if not okDisplay and displayErr and displayErr ~= "" then
            log(displayErr, LogLevel.warn)
        end
        rerenderAllTabs()
        draw()
        return true
    end
    if hitRegion(x, y, controls.exitButton) then
        state.running = false
        return true
    end
    return true
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

function openHelpTab()
    local existingIndex = findFirstTabByUrlPrefix("about:help")
    if existingIndex then
        activateTab(existingIndex)
        return
    end

    local tab = newTab("about:help")
    navigate("about:help", true, false, tab)
end

function openOrFocusFavoritesTab()
    local existingIndex = findFirstTabByUrlPrefix("about:favorites")
    if existingIndex then
        activateTab(existingIndex)
        return
    end

    local tab = newTab("about:favorites")
    navigate("about:favorites", true, false, tab)
end

function openOrFocusHistoryTab()
    local existingIndex = findFirstTabByUrlPrefix("about:history")
    if existingIndex then
        activateTab(existingIndex)
        return
    end

    local tab = newTab("about:history")
    navigate("about:history", true, false, tab)
end

function pageLineToPrintableText(line, width)
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

function printablePageLines(tab)
    local target = tab or activeTab()
    local terminalWidth = term and term.getSize and term.getSize() or 1
    local width = math.max(1, tonumber(target.viewportWidth) or tonumber(terminalWidth) or 1)
    local lines = target.pageLines or { createEmptyLine() }
    local totalLines = math.max(1, pageLineCount(target))

    local output = {}
    for index = 1, totalLines do
        output[#output + 1] = pageLineToPrintableText(lines[index], width)
    end
    while #output > 1 and output[#output] == "" do
        table.remove(output)
    end
    return output
end

function listPrinterNames()
    local names = {}
    if not peripheral or type(peripheral.getNames) ~= "function" or type(peripheral.getType) ~= "function" then
        return names
    end
    for _, name in ipairs(peripheral.getNames() or {}) do
        local typeName = tostring(peripheral.getType(name) or ""):lower()
        if typeName == "printer" then
            names[#names + 1] = tostring(name)
        end
    end
    table.sort(names)
    return names
end

function wrapPrintLine(line, width)
    local source = tostring(line or "")
    local chunks = {}
    local chunkWidth = math.max(1, tonumber(width) or 1)
    if source == "" then
        chunks[1] = ""
        return chunks
    end
    local startIndex = 1
    while startIndex <= #source do
        chunks[#chunks + 1] = source:sub(startIndex, startIndex + chunkWidth - 1)
        startIndex = startIndex + chunkWidth
    end
    return chunks
end

function printLinesToPeripheral(printerDevice, lines, pageTitle)
    return printing.printLinesToPeripheral(printerDevice, lines, pageTitle, wrapPrintLine)
end

function promptPrinterSelection(printerNames)
    if #printerNames == 0 then
        return nil
    end
    if #printerNames == 1 then
        return printerNames[1]
    end

    local choice = nil
    local buttons = {}
    local keyActions = {}
    local maxShown = math.min(#printerNames, 9)
    local digitKeyNames = {
        "one",
        "two",
        "three",
        "four",
        "five",
        "six",
        "seven",
        "eight",
        "nine",
    }
    for index = 1, maxShown do
        local id = "select_" .. tostring(index)
        local short = "[" .. tostring(index) .. "]"
        local label = short .. " " .. tostring(printerNames[index])
        buttons[#buttons + 1] = {
            id = id,
            label = label,
            shortLabel = short,
            background = colors.gray,
            foreground = colors.white,
        }
        local keyName = digitKeyNames[index]
        local keyConstant = keyName and keys and keys[keyName] or nil
        if keyConstant then
            keyActions[keyConstant] = id
        end
    end
    buttons[#buttons + 1] = {
        id = "cancel",
        label = "[Cancel]",
        shortLabel = "[X]",
        background = colors.red,
        foreground = colors.white,
    }
    if keys and keys.escape then
        keyActions[keys.escape] = "cancel"
    end

    local infoLines = {
        "Multiple printers detected.",
        "Choose where to print this page:",
    }
    for index = 1, maxShown do
        infoLines[#infoLines + 1] = ("%d) %s"):format(index, tostring(printerNames[index]))
    end
    if #printerNames > maxShown then
        infoLines[#infoLines + 1] = ("Showing first %d printers only."):format(maxShown)
    end

    openModal({
        id = "printer_select",
        title = "Select Printer",
        titleBackground = colors.blue,
        titleForeground = colors.white,
        lines = infoLines,
        buttons = buttons,
        keyActions = keyActions,
        autoClose = false,
        onButton = function(buttonId)
            choice = buttonId
            clearModal()
            return false
        end,
    })
    draw()

    while choice == nil and state.modal.open do
        local event = { os.pullEvent() }
        handleModalEvent(event)
        if state.running then
            draw()
        end
    end

    local selectedIndex = tonumber(tostring(choice or ""):match("^select_(%d+)$"))
    if selectedIndex and printerNames[selectedIndex] then
        return printerNames[selectedIndex]
    end
    return nil
end

function printCurrentPage(tab)
    local target = tab or activeTab()
    local printers = listPrinterNames()
    if #printers == 0 then
        target.status = "Print failed: no printer peripheral found"
        log(target.status, LogLevel.warn)
        return false
    end

    local selectedPrinter = promptPrinterSelection(printers)
    if not selectedPrinter then
        target.status = "Print canceled"
        log(target.status, LogLevel.info)
        return false
    end

    local printerDevice = peripheral.wrap(selectedPrinter)
    if not printerDevice then
        target.status = "Print failed: could not access printer '" .. tostring(selectedPrinter) .. "'"
        log(target.status, LogLevel.error)
        return false
    end

    local pageTitle = trim((target.document and target.document.title) or "")
    if pageTitle == "" then
        pageTitle = trim(target.currentUrl or "")
    end
    local lines = printablePageLines(target)
    local payload = {
        "Title: " .. pageTitle,
        "URL: " .. trim(target.currentUrl or ""),
    }
    if os and type(os.date) == "function" then
        local okDate, dateText = pcall(os.date, "%Y-%m-%d %H:%M:%S")
        if okDate and dateText then
            payload[#payload + 1] = "Printed: " .. tostring(dateText)
        end
    end
    payload[#payload + 1] = ""
    for _, line in ipairs(lines) do
        payload[#payload + 1] = line
    end

    local okPrint, printErr, printedPages = printLinesToPeripheral(printerDevice, payload, pageTitle)
    if not okPrint then
        local prefix = "Print failed: "
        if tonumber(printedPages) and printedPages > 0 then
            prefix = ("Print failed after %d pages: "):format(math.floor(printedPages))
        end
        target.status = prefix .. tostring(printErr or "unknown error")
        log(target.status, LogLevel.error)
        return false
    end

    local pageCount = math.max(1, math.floor(tonumber(printedPages) or 0))
    target.status = ("Printed %d pages on %s"):format(pageCount, tostring(selectedPrinter))
    log(target.status, LogLevel.info)
    showSnackbar(("Printed %d pages"):format(pageCount), 1200)
    return true
end

function suggestedDownloadPath(url, body, headers)
    local sourceUrl = trim(tostring(url or ""))
    local name = sourceUrl:gsub("[?#].*$", ""):match("([^/\\]+)$") or ""
    local contentType = trim(tostring(getHeader(headers, "Content-Type") or "")):lower()
    local function sanitizeFileName(rawName)
        local cleaned = trim(tostring(rawName or ""))
        cleaned = cleaned:gsub("[^%w%._%-]", "_")
        cleaned = cleaned:gsub("_+", "_")
        cleaned = cleaned:gsub("^%.*", "")
        cleaned = cleaned:gsub("%.*$", "")
        if cleaned == "" then
            cleaned = "download"
        end
        return cleaned
    end

    if name == "" then
        if contentType:find("html", 1, true) or looksLikeHtml(body or "", contentType) then
            name = "index.html"
        elseif contentType:find("lua", 1, true) then
            name = "download.lua"
        else
            name = "download.txt"
        end
    elseif not name:match("%.[%w]+$") then
        if contentType:find("html", 1, true) or looksLikeHtml(body or "", contentType) then
            name = name .. ".html"
        elseif contentType:find("lua", 1, true) then
            name = name .. ".lua"
        else
            name = name .. ".txt"
        end
    end
    name = sanitizeFileName(name)
    return fs.combine(currentDownloadsDir(), name)
end

function downloadCurrentPage(tab)
    local target = tab or activeTab()
    local currentUrl = trim(tostring(target.currentUrl or target.urlInput or ""))
    if currentUrl == "" then
        target.status = "Download failed: no active URL"
        log(target.status, LogLevel.warn)
        return false
    end

    local body, finalUrl, headers, err = fetchTextResource(currentUrl, false)
    if not body then
        target.status = "Download failed: " .. tostring(err or "unknown error")
        log(target.status, LogLevel.error)
        return false
    end

    local okStorage, storageErr = ensureStoragePaths()
    if not okStorage then
        target.status = "Download failed: " .. tostring(storageErr or "storage unavailable")
        log(target.status, LogLevel.error)
        return false
    end

    local preferredPath = suggestedDownloadPath(finalUrl or currentUrl, body, headers)
    local savePath = preferredPath
    if fs.exists(savePath) and fs.isDir(savePath) then
        savePath = fs.combine(currentDownloadsDir(), "download.txt")
    end

    local function splitName(path)
        local filename = fs.getName(path)
        local stem, ext = filename:match("^(.*)%.([%w]+)$")
        if not stem or stem == "" then
            stem = filename
            ext = nil
        end
        return stem, ext
    end

    if fs.exists(savePath) then
        local directory = fs.getDir(savePath)
        local stem, ext = splitName(savePath)
        local suffix = 1
        while fs.exists(savePath) do
            local candidate = stem .. "-" .. tostring(suffix)
            if ext and ext ~= "" then
                candidate = candidate .. "." .. ext
            end
            savePath = fs.combine(directory, candidate)
            suffix = suffix + 1
        end
    end

    local okWrite, writeErr = writeTextFile(savePath, body)
    if not okWrite then
        target.status = "Download failed: " .. tostring(writeErr or "could not write file")
        log(target.status, LogLevel.error)
        return false
    end

    target.status = ("Downloaded %d bytes to %s"):format(#tostring(body or ""), tostring(savePath))
    log(target.status, LogLevel.info)
    showSnackbar("Download complete", 1200)
    return true
end

function toggleCurrentPageFavorite()
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

function toggleFullscreen(forceExitSeamless)
    if state.fullscreen then
        if state.seamlessAppletFullscreen and not forceExitSeamless then
            activeTab().status = "Seamless fullscreen active (press Ctrl+K to exit)"
            return false
        end
        state.fullscreen = false
        state.seamlessAppletFullscreen = false
        state.menuOpen = false
        rerenderAllTabs()
        return true
    end

    state.menuOpen = false
    state.seamlessAppletFullscreen = seamlessFullscreenSettingEnabled()
    state.fullscreen = true
    state.menuOpen = false
    rerenderAllTabs()
    return true
end

function hitMenuPanel(x, y)
    local menu = state.ui.menu
    local panel = menu and menu.panel or nil
    if not panel then
        return false
    end
    return x >= panel.x1 and x <= panel.x2 and y >= panel.y1 and y <= panel.y2
end

function handleMenuClick(x, y)
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
    if hitRegion(x, y, menu.download) then
        state.menuOpen = false
        downloadCurrentPage()
        return true
    end
    if hitRegion(x, y, menu.print) then
        state.menuOpen = false
        printCurrentPage()
        return true
    end
    if hitRegion(x, y, menu.fullscreen) then
        toggleFullscreen()
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

function urlEncode(value)
    local source = tostring(value or "")
    return (source:gsub("([^%w%-_%.~])", function(ch)
        return ("%%%02X"):format(string.byte(ch))
    end))
end

function encodeFormFields(fields)
    local parts = {}
    for _, field in ipairs(fields or {}) do
        local name = urlEncode(field.name or "")
        local value = urlEncode(field.value or "")
        parts[#parts + 1] = name .. "=" .. value
    end
    return table.concat(parts, "&")
end

function appendQuery(url, query)
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

function formControl(tab, key)
    local target = tab or activeTab()
    local meta = target.formMeta or {}
    local controls = meta.controlsByKey or {}
    local resolvedKey = key
    local colorOptionIndex = nil
    local colorAction = nil
    local control = controls[resolvedKey]
    if not control then
        local rawKey = tostring(key or "")
        local baseKey, optionIndexText = rawKey:match("^(.-)::color:(%d+)$")
        local baseKeyAction, actionName = rawKey:match("^(.-)::color:(prev)$")
        if not baseKeyAction then
            baseKeyAction, actionName = rawKey:match("^(.-)::color:(open)$")
        end
        if not baseKeyAction then
            baseKeyAction, actionName = rawKey:match("^(.-)::color:(next)$")
        end
        if baseKey and baseKey ~= "" then
            local candidate = controls[baseKey]
            if candidate and candidate.tag == "input" and tostring(candidate.inputType or ""):lower() == "color" then
                resolvedKey = baseKey
                control = candidate
                colorOptionIndex = tonumber(optionIndexText)
            end
        elseif baseKeyAction and baseKeyAction ~= "" then
            local candidate = controls[baseKeyAction]
            if candidate and candidate.tag == "input" and tostring(candidate.inputType or ""):lower() == "color" then
                resolvedKey = baseKeyAction
                control = candidate
                colorAction = actionName
            end
        end
    end
    if not control then
        return nil, nil, nil, nil, nil
    end
    target.formState = target.formState or {}
    local stateEntry = target.formState[resolvedKey]
    if not stateEntry then
        stateEntry = {}
        target.formState[resolvedKey] = stateEntry
    end
    return control, stateEntry, resolvedKey, colorOptionIndex, colorAction
end

function isEditableFormControl(control)
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
        or inputType == "image"
        or inputType == "color" then
        return false
    end
    return true
end

function setFocusedFormControl(tab, key)
    local target = tab or activeTab()
    local changed = target.focusedFormControl ~= key or target.urlFocus
    target.focusedFormControl = key
    target.urlFocus = false
    clearUrlSelection(target)
    if changed then
        bumpRenderRevision(target)
    end
end

local clampControlCursor = formControls.clampCursor
local insertIntoFormControl = formControls.insert
local removeFromFormControl = formControls.remove

copyControlDefaults = formControls.copyControlDefaults

function resetForm(tab, formId)
    local target = tab or activeTab()
    return formControls.resetForm(target, formId, bumpRenderRevision)
end

pushFormField = formControls.pushFormField
collectInputFormField = formControls.collectInputFormField
collectSelectFormField = formControls.collectSelectFormField
collectButtonFormField = formControls.collectButtonFormField

function collectFormFields(tab, formId, submitterKey)
    local target = tab or activeTab()
    return formControls.collectFormFields(target, formId, submitterKey)
end

function refreshCurrentDocumentWithoutNavigation(tab)
    local target = tab or activeTab()
    local currentUrl = trim(target.currentUrl or "")
    if currentUrl == "" then
        return false
    end
    state.highUsage.loadingFrame = true

    local previous = {
        scroll = target.scroll or 0,
        formState = target.formState or {},
        focusedControl = target.focusedFormControl,
        urlFocused = target.urlFocus and true or false,
        urlInput = target.urlInput or currentUrl,
        urlCursor = target.urlCursor,
        urlOffset = target.urlOffset,
        urlSelStart = target.urlSelStart,
        urlSelEnd = target.urlSelEnd,
    }
    previous.urlCursor = previous.urlCursor or (#previous.urlInput + 1)
    previous.urlOffset = previous.urlOffset or 0

    local loaded = {
        body = nil,
        finalUrl = nil,
        headers = nil,
    }

    loaded.body, loaded.finalUrl, loaded.headers, loaded.err = fetchTextResource(currentUrl, false)
    if not loaded.body then
        loaded.finalUrl = currentUrl
        loaded.body = makeErrorPage(loaded.finalUrl, loaded.err or "Unknown error")
        loaded.headers = { ["Content-Type"] = "text/html" }
    end

    local contentType = getHeader(loaded.headers, "Content-Type") or ""
    if not looksLikeHtml(loaded.body, contentType) then
        loaded.body = "<html><body><pre>" .. escapeHtml(loaded.body) .. "</pre></body></html>"
    end

    loaded.resolvedUrl = loaded.finalUrl or currentUrl
    target.document = buildDocument(loaded.body, loaded.resolvedUrl)
    target.currentUrl = loaded.resolvedUrl
    target.aboutUpdateIntervalMs = parseAboutUpdateIntervalMs(loaded.headers)
    target.settingsStickyStatus = parseSettingsStatusMessage(loaded.headers, loaded.resolvedUrl)
    target.status = target.document.title or target.status

    if previous.urlFocused then
        target.urlInput = previous.urlInput
        target.urlCursor = clamp(previous.urlCursor, 1, #target.urlInput + 1)
        target.urlOffset = math.max(0, tonumber(previous.urlOffset) or 0)
        target.urlFocus = true
        target.urlSelStart = previous.urlSelStart
        target.urlSelEnd = previous.urlSelEnd
    else
        target.urlInput = loaded.resolvedUrl
        target.urlCursor = #target.urlInput + 1
        target.urlOffset = 0
        target.urlFocus = false
        clearUrlSelection(target)
    end

    target.formState = previous.formState
    target.formMeta = nil
    target.focusedFormControl = previous.focusedControl
    target.renderRevision = 0
    target.lastRenderSignature = nil
    target.scroll = previous.scroll
    renderDocument(target)
    if scheduleAboutUpdateTimer then
        scheduleAboutUpdateTimer()
    end
    return true
end

function submitForm(tab, formId, submitterKey)
    local target = tab or activeTab()
    local ctx = {
        target = target,
        meta = target.formMeta or {},
    }
    ctx.forms = ctx.meta.formsById or {}
    ctx.controls = ctx.meta.controlsByKey or {}
    ctx.form = ctx.forms[formId]
    if not ctx.form then
        return false
    end

    ctx.submitter = submitterKey and ctx.controls[submitterKey] or nil
    ctx.method = ctx.submitter and trim(ctx.submitter.formMethod or "") or ""
    if ctx.method == "" then
        ctx.method = trim(ctx.form.method or "")
    end
    ctx.method = ctx.method:lower()
    if ctx.method ~= "post" then
        ctx.method = "get"
    end

    ctx.action = ctx.submitter and trim(ctx.submitter.formAction or "") or ""
    if ctx.action == "" then
        ctx.action = trim(ctx.form.action or "")
    end
    if ctx.action == "" then
        ctx.action = ctx.target.currentUrl or "about:blank"
    end
    ctx.action = core.resolveRelativeUrl(ctx.target.currentUrl or ctx.action, ctx.action)

    ctx.encoded = encodeFormFields(collectFormFields(ctx.target, formId, submitterKey))
    ctx.requestUrl = ctx.action
    ctx.requestOptions = {
        method = ctx.method:upper(),
    }

    if ctx.method == "post" then
        ctx.enctype = ctx.submitter and trim(ctx.submitter.formEnctype or "") or ""
        if ctx.enctype == "" then
            ctx.enctype = trim(ctx.form.enctype or "")
        end
        if ctx.enctype == "" then
            ctx.enctype = "application/x-www-form-urlencoded"
        end
        ctx.requestOptions.headers = {
            ["Content-Type"] = ctx.enctype,
        }
        ctx.requestOptions.body = ctx.encoded
    else
        ctx.requestUrl = appendQuery(ctx.action, ctx.encoded)
    end

    ctx.err = select(4, fetchTextResource(ctx.requestUrl, true, ctx.requestOptions))
    if ctx.err then
        ctx.target.status = "Form submit failed: " .. tostring(ctx.err)
        log(ctx.target.status .. " (" .. tostring(ctx.requestUrl) .. ")", LogLevel.warn)
        return false
    end

    ctx.target.status = "Form submitted"
    log(ctx.target.status .. " (" .. tostring(ctx.requestUrl) .. ")", LogLevel.info)
    local currentAboutUrl = trim(ctx.target.currentUrl or ""):lower()
    if startsWith(currentAboutUrl, "about:history") then
        navigate(ctx.requestUrl, false, false, ctx.target, ctx.requestOptions)
        focusHistorySearchInput(ctx.target)
    elseif startsWith(currentAboutUrl, "about:") then
        refreshCurrentDocumentWithoutNavigation(ctx.target)
    end
    return true
end

function focusHistorySearchInput(tab)
    local target = tab or activeTab()
    local formMeta = target.formMeta or {}
    local controls = formMeta.controlsByKey or {}
    for _, key in ipairs(formMeta.controlOrder or {}) do
        local control = controls[key]
        if control and control.tag == "input" then
            local inputType = tostring(control.inputType or "text"):lower()
            local name = trim(tostring(control.name or "")):lower()
            if (inputType == "text" or inputType == "search") and name == "q" then
                setFocusedFormControl(target, key)
                local _, stateEntry = formControl(target, key)
                if stateEntry then
                    stateEntry.cursor = #tostring(stateEntry.value or "") + 1
                end
                target.urlFocus = false
                bumpRenderRevision(target)
                return true
            end
        end
    end
    return false
end

function cycleSelect(tab, control, stateEntry, direction)
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

function cycleColorInput(tab, control, stateEntry, direction)
    local target = tab or activeTab()
    local options = control.colorOptions or {}
    if #options == 0 then
        return false
    end

    local currentIndex = tonumber(stateEntry.colorIndex)
    if not currentIndex then
        local currentValue = trim(tostring(stateEntry.value or "")):lower()
        for i, name in ipairs(options) do
            if name == currentValue then
                currentIndex = i
                break
            end
        end
    end
    currentIndex = clamp(math.floor(currentIndex or 1), 1, #options)
    local nextIndex = currentIndex + (direction or 1)
    if nextIndex < 1 then
        nextIndex = #options
    elseif nextIndex > #options then
        nextIndex = 1
    end

    stateEntry.colorIndex = nextIndex
    stateEntry.value = tostring(options[nextIndex] or options[1] or "white")
    bumpRenderRevision(target)
    return true
end

function setColorInputIndex(tab, control, stateEntry, requestedIndex)
    local target = tab or activeTab()
    local options = control.colorOptions or {}
    if #options == 0 then
        return false
    end
    local index = tonumber(requestedIndex)
    if not index then
        return false
    end
    index = clamp(math.floor(index), 1, #options)
    stateEntry.colorIndex = index
    stateEntry.value = tostring(options[index] or options[1] or "white")
    stateEntry.colorFlyoutOpen = true
    bumpRenderRevision(target)
    return true
end

function openColorInputFlyout(tab, stateEntry)
    local target = tab or activeTab()
    stateEntry.colorFlyoutOpen = true
    bumpRenderRevision(target)
    return true
end

function activateRadioGroup(target, control, key, stateEntry)
    local formId = control.formId
    local name = trim(tostring(control.name or ""))
    if not formId or name == "" then
        stateEntry.checked = true
        return
    end

    local formMeta = target.formMeta or {}
    local form = formMeta.formsById and formMeta.formsById[formId] or nil
    local controls = formMeta.controlsByKey or {}
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
end

function activateInputControl(target, control, stateEntry, key)
    local inputType = tostring(control.inputType or "text"):lower()
    if inputType == "checkbox" then
        stateEntry.checked = not not stateEntry.checked
        bumpRenderRevision(target)
        return true
    end
    if inputType == "radio" then
        activateRadioGroup(target, control, key, stateEntry)
        bumpRenderRevision(target)
        return true
    end
    if inputType == "submit" or inputType == "image" then
        if control.formId then
            return submitForm(target, control.formId, key)
        end
        return true
    end
    if inputType == "color" then
        return cycleColorInput(target, control, stateEntry, 1)
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

function activateButtonControl(target, control, key)
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

function activateFormControl(tab, key)
    local target = tab or activeTab()
    local control, stateEntry, resolvedKey, colorOptionIndex, colorAction = formControl(target, key)
    if not control or control.disabled then
        return false
    end

    setFocusedFormControl(target, resolvedKey)
    if colorOptionIndex
        and control.tag == "input"
        and tostring(control.inputType or ""):lower() == "color" then
        return setColorInputIndex(target, control, stateEntry, colorOptionIndex)
    end
    if colorAction
        and control.tag == "input"
        and tostring(control.inputType or ""):lower() == "color" then
        if colorAction == "prev" then
            stateEntry.colorFlyoutOpen = true
            return cycleColorInput(target, control, stateEntry, -1)
        end
        if colorAction == "next" then
            stateEntry.colorFlyoutOpen = true
            return cycleColorInput(target, control, stateEntry, 1)
        end
        if colorAction == "open" then
            return openColorInputFlyout(target, stateEntry)
        end
    end

    if control.tag == "input" then
        return activateInputControl(target, control, stateEntry, resolvedKey)
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
        return activateButtonControl(target, control, resolvedKey)
    end

    return false
end

function moveFocusedFormControl(tab, direction)
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

function handleFocusedFormControlKey(tab, key)
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
            if inputType == "color" then
                return cycleColorInput(target, control, stateEntry, 1)
            end
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
            if inputType == "color" then
                return cycleColorInput(target, control, stateEntry, 1)
            end
            if inputType == "checkbox" or inputType == "radio" or inputType == "submit" or inputType == "reset" or inputType == "button" then
                return activateFormControl(target, control.key)
            end
        elseif control.tag == "select" or control.tag == "button" then
            return activateFormControl(target, control.key)
        end
    end

    if control.tag == "input" then
        local inputType = tostring(control.inputType or "text"):lower()
        if inputType == "color" and (key == keys.left or key == keys.up or key == keys.right or key == keys.down) then
            local direction = (key == keys.left or key == keys.up) and -1 or 1
            return cycleColorInput(target, control, stateEntry, direction)
        end
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

function handleFocusedFormControlChar(tab, character)
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

function handleFocusedFormControlPaste(tab, text)
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

function handleTabClick(button, x)
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

function handleToolbarClick(x)
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

function handleFullscreenMenuButtonClick(x, y)
    if not state.fullscreen then
        return false
    end
    if seamlessAppletFullscreenActive and seamlessAppletFullscreenActive() then
        return false
    end
    if not hitRegion(x, y, state.ui.menuButton) then
        return false
    end

    state.menuOpen = not state.menuOpen
    if state.menuOpen then
        local tab = activeTab()
        tab.urlFocus = false
        clearUrlSelection(tab)
        tab.focusedFormControl = nil
    end
    state.tabDrag = nil
    state.scrollbarDrag = nil
    return true
end

function handleScrollbarClick(button, x, y, tab, topRows)
    local scrollbar = verticalScrollbarMetrics(tab)
    if not scrollbar or x ~= scrollbar.x then
        return false
    end
    if button ~= 1 then
        return true
    end
    if scrollbar.maxScroll <= 0 then
        return true
    end

    local clickRow = clamp(y - topRows, 1, scrollbar.viewportHeight)
    local thumbBottom = scrollbar.thumbTop + scrollbar.thumbHeight - 1
    if clickRow >= scrollbar.thumbTop and clickRow <= thumbBottom then
        state.scrollbarDrag = {
            button = button,
            tab = tab,
            grabOffset = clickRow - scrollbar.thumbTop,
        }
    elseif clickRow < scrollbar.thumbTop then
        setScroll(tab.scroll - scrollbar.viewportHeight, tab)
    else
        setScroll(tab.scroll + scrollbar.viewportHeight, tab)
    end
    return true
end

function handlePageContentClick(button, x, y, tab, topRows)
    local viewportWidth = pageContentWidth(tab)
    local lineIndex = clamp(tab.scroll + (y - topRows), 1, pageLineCount(tab))
    local column = clamp(x, 1, viewportWidth)

    if state.caretMode then
        if button == 1 then
            setPageSelection(tab, lineIndex, column, lineIndex, column)
        end
        return true
    end

    clearPageSelection(tab)
    local line = tab.pageLines[lineIndex]
    local controlKey = line and line.controls and line.controls[column] or nil
    if controlKey then
        state.menuOpen = false
        activateFormControl(tab, controlKey)
        return true
    end

    tab.focusedFormControl = nil
    local href = line and line.links and line.links[column] or nil
    if href then
        local action = select(1, parseAppletActionUrl(href))
        if action ~= nil and tab.pendingApplet then
            state.menuOpen = false
            return handleAppletActionNavigation(href, tab)
        end
        state.menuOpen = false
        navigate(href, true, false, tab)
        return true
    end
    return false
end

function handleMouseClick(button, x, y)
    layoutUi()
    local topRows = effectiveTopBarRows()

    if state.menuOpen then
        if hitMenuPanel(x, y) then
            handleMenuClick(x, y)
            return
        end
        if not hitRegion(x, y, state.ui.menuButton) then
            state.menuOpen = false
        end
    end

    if handleFullscreenMenuButtonClick(x, y) then
        return
    end

    if not state.fullscreen then
        if y == 1 then
            handleTabClick(button, x)
            return
        end

        if y == 2 then
            handleToolbarClick(x)
            return
        end
    end

    local tab = activeTab()
    tab.urlFocus = false
    clearUrlSelection(tab)

    if handleScrollbarClick(button, x, y, tab, topRows) then
        return
    end

    handlePageContentClick(button, x, y, tab, topRows)
end

function handleMouseDrag(button, x, y)
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

        local row = clamp(y - effectiveTopBarRows(), 1, scrollbar.viewportHeight)
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
    if button ~= 1 or y <= effectiveTopBarRows() then
        return
    end

    local tab = activeTab()
    if not tab.pageSelection then
        return
    end

    local w = pageContentWidth(tab)
    local lineIndex = clamp(tab.scroll + (y - effectiveTopBarRows()), 1, pageLineCount(tab))
    local column = clamp(x, 1, w)
    tab.pageSelection.endLine = lineIndex
    tab.pageSelection.endCol = column
end

function handleMouseUp(button, _, _)
    if state.tabDrag and state.tabDrag.button == button then
        state.tabDrag = nil
    end
    if state.scrollbarDrag and state.scrollbarDrag.button == button then
        state.scrollbarDrag = nil
    end
end

function handleMouseScroll(direction, _, y)
    if y <= effectiveTopBarRows() then
        return
    end
    local tab = activeTab()
    setScroll(tab.scroll + direction, tab)
end

function focusUrlBar()
    local tab = activeTab()
    tab.urlFocus = true
    tab.urlCursor = #tab.urlInput + 1
    clearUrlSelection(tab)
end

function handleUrlKey(key)
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

function handleNavigationKey(key)
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

function selectAllText()
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

function copySelectedText()
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

    if text == "" then
        text = trim(tostring(tab.currentUrl or tab.urlInput or ""))
    end

    if text ~= "" then
        state.clipboard = text
        state.localClipboardPendingPaste = true
        return true
    end
    return false
end

function cutSelectedText()
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

function pasteClipboardText()
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

    tab.urlFocus = true
    tab.focusedFormControl = nil
    tab.urlCursor = #tab.urlInput + 1
    clearUrlSelection(tab)
    insertUrlText(state.clipboard)
    state.localClipboardPendingPaste = false
    state.skipNextPaste = true
    return true
end

function handleKeyDown(key, appletContext)
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
        if key == keys.k then
            toggleFullscreen(true)
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

    if appletContext then
        if key == keys.escape then
            if state.fullscreen then
                if not state.seamlessAppletFullscreen then
                    toggleFullscreen()
                end
            else
                state.running = false
            end
        end
        return
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
        if state.fullscreen then
            toggleFullscreen()
            return
        end
        state.running = false
        return
    end

    handleNavigationKey(key)
end

function handleKeyUp(key)
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

function handleTimer(timerId)
    if state.animationTimer and timerId == state.animationTimer then
        state.animationTimer = nil
        scheduleAnimationTick()
        if state.running then
            draw()
        end
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

function handleChar(character)
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

function resolvePasteText(text)
    local pasteText = text
    if state.localClipboardPendingPaste and state.clipboard ~= "" then
        pasteText = state.clipboard
        state.localClipboardPendingPaste = false
    end
    return pasteText
end

function handlePaste(text)
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
        return
    end

    if pasteText and pasteText ~= "" then
        tab.urlFocus = true
        tab.focusedFormControl = nil
        tab.urlCursor = #tab.urlInput + 1
        clearUrlSelection(tab)
        insertUrlText(pasteText)
        state.clipboard = pasteText
    end
end

function bootstrap(initialUrls, startupFullscreenMode, startupMonitorChoice)
    if state.initialTermBackground == nil and NATIVE_TERM and NATIVE_TERM.getBackgroundColor then
        state.initialTermBackground = NATIVE_TERM.getBackgroundColor()
    end
    if state.initialTermForeground == nil and NATIVE_TERM and NATIVE_TERM.getTextColor then
        state.initialTermForeground = NATIVE_TERM.getTextColor()
    end

    startupMonitorOverride = normalizeMonitorChoice(startupMonitorChoice)
    if startupMonitorOverride == INTERNAL_MONITOR_ID then
        startupMonitorOverride = nil
    end
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
    if runtimeDisplayTarget ~= INTERNAL_MONITOR_ID
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
    state.lastPulledEvent = { os.pullEvent() }
    if state.lastPulledEvent[1] == "monitor_touch" then
        if runtimeDisplayMonitorPeripheral and state.lastPulledEvent[2] == runtimeDisplayMonitorPeripheral then
            state.lastPulledEvent = { "mouse_click", 1, state.lastPulledEvent[3], state.lastPulledEvent[4], "monitor_touch" }
        end
    elseif state.lastPulledEvent[1] == "peripheral_detach" or state.lastPulledEvent[1] == "peripheral" then
        if runtimeDisplayMonitorPeripheral and state.lastPulledEvent[2] == runtimeDisplayMonitorPeripheral then
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
    clearSurface(runtimeDisplayTarget or INTERNAL_MONITOR_ID, bg, fg)
    clearSurface(INTERNAL_MONITOR_ID, bg, fg)
    if term and type(term.redirect) == "function" and NATIVE_TERM then
        term.redirect(NATIVE_TERM)
    end
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
