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
createDisplayManager = loadModule("app/display/manager.lua")
createTabState = loadModule("app/state/tabs.lua")
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
local rerenderAllTabs
local draw

local displayManager = createDisplayManager({
    core = core,
    term = term,
    peripheral = peripheral,
    colors = colors,
    appTitle = APP_TITLE,
    internalMonitorId = INTERNAL_MONITOR_ID,
    internalMonitorLabel = INTERNAL_MONITOR_LABEL,
    nativeTerm = NATIVE_TERM,
    browserSettings = browserSettings,
    currentDefaultBackgroundColorValue = currentDefaultBackgroundColorValue,
    currentDefaultForegroundColorValue = currentDefaultForegroundColorValue,
    persistBrowserState = function()
        if persistBrowserState then
            persistBrowserState()
        end
    end,
    getState = function()
        return state
    end,
    onDisplayChanged = function()
        if rerenderAllTabs then
            rerenderAllTabs()
        end
        if draw then
            draw()
        end
    end,
    onExitRequested = function()
        if state then
            state.running = false
        end
    end,
    log = function(message, level)
        if log then
            log(message, level)
        end
    end,
    logLevelWarn = LogLevel.warn,
})

function normalizeMonitorChoice(value)
    return displayManager.normalizeMonitorChoice(value)
end

function attachedMonitorNames()
    return displayManager.attachedMonitorNames()
end

function monitorExists(name)
    return displayManager.monitorExists(name)
end

function listMonitorTargets()
    return displayManager.listMonitorTargets()
end

function applyDisplayTarget(choice)
    return displayManager.applyDisplayTarget(choice)
end

function refreshDisplayTarget()
    return displayManager.refreshDisplayTarget()
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

