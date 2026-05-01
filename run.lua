local APP_TITLE = "CC Browser"

local function normalizeDir(path)
    local normalized = fs.combine(tostring(path or ""), "")
    if normalized ~= "/" and #normalized > 1 and normalized:sub(-1) == "/" then
        normalized = normalized:sub(1, -2)
    end
    if normalized == "" then
        normalized = "."
    end
    return normalized
end

local function looksLikeBrowserRoot(path)
    local root = normalizeDir(path)
    local appPath = fs.combine(root, "main.lua")
    local corePath = fs.combine(root, "lib/core.lua")
    return fs.exists(appPath) and not fs.isDir(appPath)
        and fs.exists(corePath) and not fs.isDir(corePath)
end

local function resolveBrowserRoot()
    local candidates = {}
    local function push(path)
        if not path or path == "" then
            return
        end
        candidates[#candidates + 1] = normalizeDir(path)
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

    if shell and type(shell.getRunningProgram) == "function" then
        local running = shell.getRunningProgram()
        if running and running ~= "" then
            push(fs.getDir(running))
            if type(shell.resolve) == "function" then
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

    local visited = {}
    for i = 1, #candidates do
        local candidate = candidates[i]
        if not visited[candidate] then
            visited[candidate] = true
            if looksLikeBrowserRoot(candidate) then
                return candidate
            end
        end
    end

    if shell and type(shell.dir) == "function" then
        return normalizeDir(shell.dir())
    end
    return "."
end

local browserRoot = resolveBrowserRoot()
local appPath = fs.combine(browserRoot, "main.lua")
if not fs.exists(appPath) then
    term.setCursorBlink(false)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.red)
    term.clear()
    term.setCursorPos(1, 1)
    print("Missing file: " .. appPath)
    return
end

_G.CC_BROWSER_BASE_DIR = browserRoot
local previousLaunchToken = rawget(_G, "CC_BROWSER_ENV")
_G.CC_BROWSER_ENV = true
local loadOk, runOrErr = pcall(dofile, appPath)
_G.CC_BROWSER_ENV = previousLaunchToken
if not loadOk then
    term.setCursorBlink(false)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.red)
    term.clear()
    term.setCursorPos(1, 1)
    print("Failed loading browser app:")
    print(appPath)
    print(tostring(runOrErr))
    return
end

local runApp = runOrErr
if type(runApp) ~= "function" then
    term.setCursorBlink(false)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.red)
    term.clear()
    term.setCursorPos(1, 1)
    print("Invalid browser app entrypoint in: " .. appPath)
    return
end

local ok, err = pcall(runApp, ...)
if not ok then
    term.setCursorBlink(false)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.red)
    term.clear()
    term.setCursorPos(1, 1)
    print(APP_TITLE .. " crashed:")
    print(tostring(err))
end
