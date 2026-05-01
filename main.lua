if rawget(_G, "CC_BROWSER_ENV") ~= true then
    printError("Do not run main.lua directly.")
    printError("Run run.lua to start the browser.")
    return
end

local function readAll(path)
    local handle, err = fs.open(path, "r")
    if not handle then
        error(("Failed to open %s: %s"):format(path, tostring(err)), 2)
    end
    local data = handle.readAll() or ""
    handle.close()
    return data
end

local function loadChunk(source, name)
    local chunk, err = load(source, name, "t", _ENV)
    if not chunk and type(loadstring) == "function" then
        chunk, err = loadstring(source, name)
        if chunk and type(setfenv) == "function" and type(getfenv) == "function" then
            setfenv(chunk, getfenv(1))
        end
    end
    if not chunk then
        error(("Failed to compile %s: %s"):format(name, tostring(err)), 2)
    end
    return chunk
end

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
    local featurePath = fs.combine(root, "app/features/01_bootstrap.lua")
    return fs.exists(appPath) and not fs.isDir(appPath)
        and fs.exists(corePath) and not fs.isDir(corePath)
        and fs.exists(featurePath) and not fs.isDir(featurePath)
end

local function resolveScriptDir()
    local candidates = {}
    local function push(path)
        if not path or path == "" then
            return
        end
        candidates[#candidates + 1] = normalizeDir(path)
    end

    if type(CC_BROWSER_BASE_DIR) == "string" and CC_BROWSER_BASE_DIR ~= "" then
        push(CC_BROWSER_BASE_DIR)
    end

    if debug and type(debug.getinfo) == "function" then
        local ok, info = pcall(debug.getinfo, 1, "S")
        if ok and type(info) == "table" and type(info.source) == "string" then
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

    if type(CC_BROWSER_BASE_DIR) == "string" and CC_BROWSER_BASE_DIR ~= "" then
        return normalizeDir(CC_BROWSER_BASE_DIR)
    end
    if shell and type(shell.dir) == "function" then
        return normalizeDir(shell.dir())
    end
    return "."
end

local scriptDir = resolveScriptDir()
local featuresDir = fs.combine(scriptDir, "app/features")
local featureFiles = {
    "01_bootstrap.lua",
    "02_settings_state.lua",
    "03_tabs_modal_render.lua",
    "04_page_actions_forms.lua",
    "05_navigation_applets.lua",
    "06_input_handlers.lua",
    "07_runtime_loop.lua",
}

local chunks = {}
for i = 1, #featureFiles do
    local path = fs.combine(featuresDir, featureFiles[i])
    chunks[#chunks + 1] = readAll(path)
end

local compiled = loadChunk(table.concat(chunks, "\n"), "@main.lua")
return compiled()
