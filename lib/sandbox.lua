-- sandbox.lua: Lua applet execution with sandboxed or full-access modes
-- Applet output is restricted to a content-area window object.

return function(deps)
    local core = deps.core
    local getVfsRoot = deps.getVfsRoot
    local VFS_ROOT = deps.vfsRoot or "/.vfs"
    local LEGACY_VFS_ROOT = "/.vfs"
    local legacyVfsMigrationAttempted = false

    local trim = core.trim
    local unpackValues = table.unpack or unpack
    local function packValues(...)
        return {
            n = select("#", ...),
            ...,
        }
    end

    local function activeVfsRoot()
        if type(getVfsRoot) == "function" then
            local root = trim(tostring(getVfsRoot() or ""))
            if root ~= "" then
                return root
            end
        end
        return VFS_ROOT
    end

    local function sanitizePathPart(value)
        local part = trim(tostring(value or "")):lower()
        part = part:gsub("[^%w%._%-]", "_")
        part = part:gsub("_+", "_")
        part = part:gsub("^_+", "")
        part = part:gsub("_+$", "")
        if part == "" then
            part = "unknown"
        end
        return part
    end

    local function appletVfsBucket(sourceUrl)
        local parsed = core.parseUrl and core.parseUrl(sourceUrl or "") or nil
        if parsed and (parsed.scheme == "http" or parsed.scheme == "https") then
            return sanitizePathPart(parsed.authority or "web")
        end
        if parsed and parsed.scheme == "file" then
            return "local_files"
        end
        if parsed and parsed.scheme then
            return sanitizePathPart(parsed.scheme)
        end
        return "unknown"
    end

    local function ensureDir(path)
        if fs.exists(path) then
            return fs.isDir(path)
        end
        local ok = pcall(fs.makeDir, path)
        return ok and fs.exists(path) and fs.isDir(path)
    end

    local function migrateLegacyVfsRoot(targetRoot)
        if legacyVfsMigrationAttempted then
            return
        end
        legacyVfsMigrationAttempted = true
        if targetRoot == LEGACY_VFS_ROOT then
            return
        end
        if not fs.exists(LEGACY_VFS_ROOT) or not fs.isDir(LEGACY_VFS_ROOT) then
            return
        end
        local targetParent = fs.getDir(targetRoot)
        if targetParent and targetParent ~= "" then
            ensureDir(targetParent)
        end
        if not fs.exists(targetRoot) then
            ensureDir(targetRoot)
        end
        local importPath = fs.combine(targetRoot, "_legacy_root")
        if not fs.exists(importPath) then
            pcall(fs.move, LEGACY_VFS_ROOT, importPath)
        end
    end

    -- Virtual filesystem: all reads/writes go under VFS_ROOT
    local function createVirtualFs(sourceUrl)
        local sharedRoot = activeVfsRoot()
        migrateLegacyVfsRoot(sharedRoot)
        ensureDir(sharedRoot)
        local vfsRoot = fs.combine(sharedRoot, appletVfsBucket(sourceUrl))
        ensureDir(vfsRoot)

        local vfs = {}

        local function resolve(path)
            local cleaned = tostring(path or "")
            cleaned = cleaned:gsub("\\", "/")
            -- Use fs.combine to normalize the path, then verify it stays within VFS_ROOT
            local combined = fs.combine(vfsRoot, cleaned)
            -- Ensure the resolved path starts with VFS_ROOT to prevent traversal
            local normalizedRoot = fs.combine(vfsRoot, "")
            if combined:sub(1, #normalizedRoot) ~= normalizedRoot then
                return fs.combine(vfsRoot, "blocked")
            end
            return combined
        end

        function vfs.open(path, mode)
            return fs.open(resolve(path), mode)
        end
        function vfs.exists(path)
            return fs.exists(resolve(path))
        end
        function vfs.isDir(path)
            return fs.isDir(resolve(path))
        end
        function vfs.list(path)
            local resolved = resolve(path)
            if not fs.exists(resolved) then
                return {}
            end
            local items = fs.list(resolved)
            -- Return enhanced list with full paths and file type information
            local result = {}
            for i, name in ipairs(items) do
                local itemPath = fs.combine(path or "", name)
                local fullPath = fs.combine(resolved, name)
                local isDir = fs.isDir(fullPath)
                local size = isDir and "-" or tostring(fs.getSize(fullPath))
                -- Escape special characters in path for safe display
                local escapedPath = itemPath:gsub("[\\\"'%c]", function(c)
                    return string.format("\\x%02X", string.byte(c))
                end)
                local escapedName = name:gsub("[\\\"'%c]", function(c)
                    return string.format("\\x%02X", string.byte(c))
                end)
                result[i] = {
                    name = name,
                    path = itemPath,
                    fullPath = fullPath,
                    isDir = isDir,
                    size = size,
                    displayName = (isDir and "[DIR] " or "[FILE] ") .. escapedName,
                    displayPath = escapedPath,
                }
            end
            -- Also return the simple list for backward compatibility
            local simpleList = {}
            for i, item in ipairs(result) do
                simpleList[i] = item.name
            end
            return simpleList, result
        end
        function vfs.makeDir(path)
            return fs.makeDir(resolve(path))
        end
        function vfs.delete(path)
            return fs.delete(resolve(path))
        end
        function vfs.move(from, to)
            return fs.move(resolve(from), resolve(to))
        end
        function vfs.copy(from, to)
            return fs.copy(resolve(from), resolve(to))
        end
        function vfs.getSize(path)
            return fs.getSize(resolve(path))
        end
        function vfs.getFreeSpace(path)
            return fs.getFreeSpace(resolve(path))
        end
        function vfs.getName(path)
            return fs.getName(tostring(path or ""))
        end
        function vfs.getDir(path)
            return fs.getDir(tostring(path or ""))
        end
        function vfs.combine(base, child)
            return fs.combine(tostring(base or ""), tostring(child or ""))
        end
        function vfs.complete(partial, path, includeFiles, includeSlashes)
            return {}
        end
        function vfs.find(wildcard)
            return {}
        end
        function vfs.isDriveRoot(path)
            return false
        end
        function vfs.getDrive(path)
            return "vfs"
        end
        function vfs.attributes(path)
            local resolved = resolve(path)
            if type(fs.attributes) == "function" then
                return fs.attributes(resolved)
            end
            return { size = 0, isDir = fs.isDir(resolved), isReadOnly = false }
        end

        return vfs
    end

    -- Build a sandboxed environment for the applet
    local function buildSandboxEnv(contentWindow, luaSource, sourceUrl)
        local vfs = createVirtualFs(sourceUrl)

        local env = {}

        -- Safe globals
        env._VERSION = _VERSION
        env.type = type
        env.tostring = tostring
        env.tonumber = tonumber
        env.pairs = pairs
        env.ipairs = ipairs
        env.next = next
        env.select = select
        env.unpack = unpack or table.unpack
        env.pcall = pcall
        env.xpcall = xpcall
        env.error = error
        env.assert = assert
        env.rawget = rawget
        env.rawset = rawset
        env.rawequal = rawequal
        env.rawlen = rawlen
        env.setmetatable = setmetatable
        env.getmetatable = getmetatable

        -- String, table, math
        env.string = string
        env.table = table
        env.math = math
        env.bit32 = bit32
        env.utf8 = utf8

        -- OS (safe subset)
        env.os = {
            clock = os.clock,
            time = os.time,
            day = os.day,
            epoch = os.epoch,
            date = os.date,
            startTimer = os.startTimer,
            cancelTimer = os.cancelTimer,
            setAlarm = os.setAlarm,
            cancelAlarm = os.cancelAlarm,
            queueEvent = os.queueEvent,
        }

        -- Textutils
        if textutils then
            env.textutils = textutils
        end

        -- Colors
        if colors then
            env.colors = colors
        end
        if colours then
            env.colours = colours
        end

        -- Keys
        if keys then
            env.keys = keys
        end

        -- Print to content window
        env.print = function(...)
            local args = { ... }
            local parts = {}
            for i = 1, #args do
                parts[i] = tostring(args[i])
            end
            local text = table.concat(parts, "\t")
            contentWindow.write(text)
            local cx, cy = contentWindow.getCursorPos()
            local cw, ch = contentWindow.getSize()
            if cy >= ch then
                contentWindow.scroll(1)
                contentWindow.setCursorPos(1, cy)
            else
                contentWindow.setCursorPos(1, cy + 1)
            end
        end

        env.write = function(text)
            contentWindow.write(tostring(text or ""))
        end

        -- Term redirected to content window
        env.term = {}
        for k, v in pairs(contentWindow) do
            if type(v) == "function" then
                env.term[k] = v
            end
        end
        -- Also provide term.native and term.current pointing to contentWindow
        env.term.native = function() return contentWindow end
        env.term.current = function() return contentWindow end
        env.term.redirect = function(target)
            -- No-op in sandbox: applet cannot redirect outside content area
            return contentWindow
        end

        -- Sandboxed filesystem
        env.fs = vfs

        -- No HTTP, no shell, no peripheral, no redstone, no turtle, no commands
        env.http = nil
        env.shell = nil
        env.peripheral = nil
        env.redstone = nil
        env.rs = nil
        env.turtle = nil
        env.commands = nil
        env.multishell = nil
        env.pocket = nil
        env.disk = nil
        env.gps = nil
        env.rednet = nil
        env.modem = nil

        -- Parallel support
        if parallel then
            env.parallel = parallel
        end

        -- Paintutils (safe, visual)
        if paintutils then
            env.paintutils = paintutils
        end

        -- Window API (so applets can create sub-windows within the content area)
        if window then
            env.window = {
                create = function(parent, x, y, w, h, visible)
                    -- Force parent to be contentWindow
                    return window.create(contentWindow, x, y, w, h, visible)
                end,
            }
        end

        -- Load/dofile restricted to virtual fs
        env.loadstring = loadstring
        env.load = load

        return env
    end

    -- Build a full-access environment for the applet
    local function buildFullAccessEnv(contentWindow, luaSource, sourceUrl)
        local env = {}

        -- Copy the full global environment
        for k, v in pairs(_G) do
            env[k] = v
        end
        env.os = {}
        for k, v in pairs(os or {}) do
            env.os[k] = v
        end

        -- Override term to point to content window
        env.term = {}
        for k, v in pairs(contentWindow) do
            if type(v) == "function" then
                env.term[k] = v
            end
        end
        env.term.native = function() return contentWindow end
        env.term.current = function() return contentWindow end
        env.term.redirect = function(target)
            return contentWindow
        end

        -- Print/write to content window
        env.print = function(...)
            local args = { ... }
            local parts = {}
            for i = 1, #args do
                parts[i] = tostring(args[i])
            end
            local text = table.concat(parts, "\t")
            contentWindow.write(text)
            local cx, cy = contentWindow.getCursorPos()
            local cw, ch = contentWindow.getSize()
            if cy >= ch then
                contentWindow.scroll(1)
                contentWindow.setCursorPos(1, cy)
            else
                contentWindow.setCursorPos(1, cy + 1)
            end
        end

        env.write = function(text)
            contentWindow.write(tostring(text or ""))
        end

        return env
    end

    local function installEventBridge(env)
        env.os = env.os or {}

        local function pullEventBridge(raw, filter)
            local wanted = filter
            while true do
                local event = packValues(coroutine.yield({
                    __cc_browser_wait = true,
                    raw = raw == true,
                    filter = wanted,
                }))
                local eventName = event[1]
                if (raw or eventName ~= "terminate") and (not wanted or eventName == wanted) then
                    return unpackValues(event, 1, event.n or #event)
                end
            end
        end

        env.os.pullEvent = function(filter)
            return pullEventBridge(false, filter)
        end
        env.os.pullEventRaw = function(filter)
            return pullEventBridge(true, filter)
        end
        env.os.queueEvent = os and os.queueEvent or nil

        env.sleep = function(seconds)
            local delay = tonumber(seconds) or 0
            if delay < 0 then
                delay = 0
            end
            if env.os and type(env.os.startTimer) == "function" then
                local timerId = env.os.startTimer(delay)
                while true do
                    local eventName, eventTimer = env.os.pullEvent("timer")
                    if eventName == "timer" and eventTimer == timerId then
                        return
                    end
                end
            end
            env.os.pullEventRaw()
        end
        env.os.sleep = env.sleep
    end

    local function buildAppletEnv(luaSource, sourceUrl, mode, contentWindow)
        local env
        if mode == "sandboxed" then
            env = buildSandboxEnv(contentWindow, luaSource, sourceUrl)
        else
            env = buildFullAccessEnv(contentWindow, luaSource, sourceUrl)
        end
        installEventBridge(env)
        return env
    end

    local function createAppletSession(luaSource, sourceUrl, mode, contentWindow)
        local env = buildAppletEnv(luaSource, sourceUrl, mode, contentWindow)
        local fn, compileErr = load(luaSource, "=" .. (sourceUrl or "applet"), "t", env)
        if not fn then
            return nil, "Compile error: " .. tostring(compileErr)
        end

        local session = {
            done = false,
            ok = nil,
            error = nil,
            waiting = false,
            waitingFilter = nil,
            waitingRaw = false,
            started = false,
        }

        local appletCoroutine = coroutine.create(function()
            local ok, runtimeErr = pcall(fn)
            if not ok then
                return false, "Runtime error: " .. tostring(runtimeErr)
            end
            return true, nil
        end)

        local function handleResumeResult(resumeOk, resultA, resultB)
            if not resumeOk then
                session.done = true
                session.ok = false
                session.error = "Runtime error: " .. tostring(resultA)
                session.waiting = false
                session.waitingFilter = nil
                session.waitingRaw = false
                return false
            end

            if coroutine.status(appletCoroutine) == "dead" then
                session.done = true
                session.ok = resultA ~= false
                if session.ok then
                    session.error = nil
                else
                    session.error = tostring(resultB or "Unknown error")
                end
                session.waiting = false
                session.waitingFilter = nil
                session.waitingRaw = false
                return true
            end

            if type(resultA) == "table" and resultA.__cc_browser_wait then
                session.waiting = true
                session.waitingFilter = resultA.filter
                session.waitingRaw = resultA.raw == true
            else
                session.waiting = true
                session.waitingFilter = nil
                session.waitingRaw = true
            end
            return true
        end

        local function resumeSession(...)
            local resumeOk, resultA, resultB = coroutine.resume(appletCoroutine, ...)
            return handleResumeResult(resumeOk, resultA, resultB)
        end

        function session.pump()
            if session.done then
                return false
            end
            if not session.started then
                session.started = true
                resumeSession()
                return not session.done
            end
            if not session.waiting then
                resumeSession()
            end
            return not session.done
        end

        function session.deliverEvent(event)
            if session.done then
                return false
            end
            if not session.started then
                session.started = true
                resumeSession()
                if session.done then
                    return false
                end
            end
            if not session.waiting then
                return true
            end

            local packed = event
            if type(packed) ~= "table" then
                packed = packValues(event)
            elseif packed.n == nil then
                packed.n = #packed
            end

            session.waiting = false
            resumeSession(unpackValues(packed, 1, packed.n))
            return not session.done
        end

        function session.terminate()
            return session.deliverEvent(packValues("terminate"))
        end

        session.pump()
        return session, nil
    end

    -- Execute a Lua applet within the content window area.
    -- mode: "sandboxed" or "full"
    -- Returns: ok (boolean), error message (string or nil)
    local function executeApplet(luaSource, sourceUrl, mode, contentWindow)
        local session, sessionErr = createAppletSession(luaSource, sourceUrl, mode, contentWindow)
        if not session then
            return false, sessionErr
        end
        while not session.done do
            local event = packValues(os.pullEventRaw())
            session.deliverEvent(event)
        end
        return session.ok, session.error
    end

    return {
        executeApplet = executeApplet,
        createAppletSession = createAppletSession,
        createVirtualFs = createVirtualFs,
    }
end
