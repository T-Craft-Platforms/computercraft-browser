-- sandbox.lua: isolated Lua applet runtime with private per-session filesystem.

return function(deps)
    local core = deps.core
    local getVfsRoot = deps.getVfsRoot
    local DEFAULT_VFS_ROOT = deps.vfsRoot or "/.vfs"
    local trim = core.trim
    local unpackValues = table.unpack or unpack
    local sessionCounter = 0

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
        return DEFAULT_VFS_ROOT
    end

    local function ensureDir(path)
        if fs.exists(path) then
            return fs.isDir(path)
        end
        local okMake = pcall(fs.makeDir, path)
        return okMake and fs.exists(path) and fs.isDir(path)
    end

    local function nextSessionId()
        sessionCounter = sessionCounter + 1
        local epochPart = 0
        if os and type(os.epoch) == "function" then
            local okEpoch, epochValue = pcall(os.epoch, "utc")
            if okEpoch and type(epochValue) == "number" then
                epochPart = math.floor(epochValue)
            end
        end
        local clockPart = 0
        if os and type(os.clock) == "function" then
            clockPart = math.floor(os.clock() * 1000000)
        end
        local entropy = tostring({}):gsub("[^%x]", ""):sub(-8)
        if entropy == "" then
            entropy = tostring(sessionCounter)
        end
        return ("session-%d-%d-%d-%s"):format(epochPart, clockPart, sessionCounter, entropy)
    end

    local function normalizeRootPrefix(path)
        local normalized = fs.combine(path, "")
        if #normalized > 1 and normalized:sub(-1) == "/" then
            normalized = normalized:sub(1, -2)
        end
        local prefix = normalized
        if prefix:sub(-1) ~= "/" then
            prefix = prefix .. "/"
        end
        return normalized, prefix
    end

    local function isPathInside(root, candidate)
        local normalizedRoot, rootPrefix = normalizeRootPrefix(root)
        if candidate == normalizedRoot then
            return true
        end
        return candidate:sub(1, #rootPrefix) == rootPrefix
    end

    local function createVirtualFs(_sourceUrl, sessionId)
        local sharedRoot = activeVfsRoot()
        if not ensureDir(sharedRoot) then
            return nil, "Could not prepare applet storage root"
        end

        local safeSessionId = trim(tostring(sessionId or nextSessionId()))
        safeSessionId = safeSessionId:gsub("[^%w%._%-]", "_")
        if safeSessionId == "" then
            safeSessionId = nextSessionId()
        end

        local sessionRoot = fs.combine(sharedRoot, safeSessionId)
        if not ensureDir(sessionRoot) then
            return nil, "Could not prepare applet session storage"
        end

        local function resolve(path)
            local cleaned = tostring(path or "")
            cleaned = cleaned:gsub("\\", "/")
            local combined = fs.combine(sessionRoot, cleaned)
            if not isPathInside(sessionRoot, combined) then
                return nil
            end
            return combined
        end

        local vfs = {}

        function vfs.open(path, mode)
            local resolved = resolve(path)
            if not resolved then
                return nil
            end
            return fs.open(resolved, mode)
        end

        function vfs.exists(path)
            local resolved = resolve(path)
            return resolved ~= nil and fs.exists(resolved) or false
        end

        function vfs.isDir(path)
            local resolved = resolve(path)
            return resolved ~= nil and fs.isDir(resolved) or false
        end

        function vfs.list(path)
            local resolved = resolve(path)
            if not resolved or not fs.exists(resolved) or not fs.isDir(resolved) then
                return {}
            end
            return fs.list(resolved)
        end

        function vfs.makeDir(path)
            local resolved = resolve(path)
            if not resolved then
                return false
            end
            if fs.exists(resolved) then
                return fs.isDir(resolved)
            end
            local parent = fs.getDir(resolved)
            if parent and parent ~= "" then
                ensureDir(parent)
            end
            local okMake = pcall(fs.makeDir, resolved)
            return okMake and fs.exists(resolved) and fs.isDir(resolved)
        end

        function vfs.delete(path)
            local resolved = resolve(path)
            if not resolved or resolved == sessionRoot then
                return false
            end
            return pcall(fs.delete, resolved)
        end

        function vfs.move(from, to)
            local fromResolved = resolve(from)
            local toResolved = resolve(to)
            if not fromResolved or not toResolved then
                return false
            end
            local toParent = fs.getDir(toResolved)
            if toParent and toParent ~= "" then
                ensureDir(toParent)
            end
            return pcall(fs.move, fromResolved, toResolved)
        end

        function vfs.copy(from, to)
            local fromResolved = resolve(from)
            local toResolved = resolve(to)
            if not fromResolved or not toResolved then
                return false
            end
            local toParent = fs.getDir(toResolved)
            if toParent and toParent ~= "" then
                ensureDir(toParent)
            end
            return pcall(fs.copy, fromResolved, toResolved)
        end

        function vfs.getSize(path)
            local resolved = resolve(path)
            if not resolved or not fs.exists(resolved) then
                return 0
            end
            return fs.getSize(resolved)
        end

        function vfs.getFreeSpace(path)
            local resolved = resolve(path)
            if not resolved then
                return 0
            end
            return fs.getFreeSpace(resolved)
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

        function vfs.complete(_partial, _path, _includeFiles, _includeSlashes)
            return {}
        end

        function vfs.find(_wildcard)
            return {}
        end

        function vfs.isDriveRoot(_path)
            return false
        end

        function vfs.getDrive(_path)
            return "applet-vfs"
        end

        function vfs.attributes(path)
            local resolved = resolve(path)
            if not resolved then
                return nil
            end
            if type(fs.attributes) == "function" then
                return fs.attributes(resolved)
            end
            return {
                size = fs.exists(resolved) and fs.getSize(resolved) or 0,
                isDir = fs.exists(resolved) and fs.isDir(resolved) or false,
                isReadOnly = false,
            }
        end

        vfs.__sessionRoot = sessionRoot
        return vfs, nil
    end

    local function writeToContentWindow(contentWindow, text)
        contentWindow.write(tostring(text or ""))
    end

    local function printToContentWindow(contentWindow, ...)
        local args = { ... }
        local parts = {}
        for i = 1, #args do
            parts[i] = tostring(args[i])
        end
        writeToContentWindow(contentWindow, table.concat(parts, "\t"))
        local _, cy = contentWindow.getCursorPos()
        local _, ch = contentWindow.getSize()
        if cy >= ch then
            contentWindow.scroll(1)
            contentWindow.setCursorPos(1, cy)
        else
            contentWindow.setCursorPos(1, cy + 1)
        end
    end

    local function buildSandboxEnv(contentWindow, sourceUrl, sessionId)
        local vfs, vfsErr = createVirtualFs(sourceUrl, sessionId)
        if not vfs then
            return nil, vfsErr
        end

        local env = {}

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
        env.string = string
        env.table = table
        env.math = math
        env.bit32 = bit32
        env.utf8 = utf8

        env.os = {
            clock = os and os.clock or nil,
            time = os and os.time or nil,
            day = os and os.day or nil,
            epoch = os and os.epoch or nil,
            date = os and os.date or nil,
            startTimer = os and os.startTimer or nil,
            cancelTimer = os and os.cancelTimer or nil,
            setAlarm = os and os.setAlarm or nil,
            cancelAlarm = os and os.cancelAlarm or nil,
            queueEvent = os and os.queueEvent or nil,
        }

        if textutils then
            env.textutils = textutils
        end
        if colors then
            env.colors = colors
        end
        if colours then
            env.colours = colours
        end
        if keys then
            env.keys = keys
        end
        if parallel then
            env.parallel = parallel
        end
        if paintutils then
            env.paintutils = paintutils
        end

        env.print = function(...)
            printToContentWindow(contentWindow, ...)
        end
        env.write = function(text)
            writeToContentWindow(contentWindow, text)
        end

        env.term = {}
        for k, v in pairs(contentWindow) do
            if type(v) == "function" then
                env.term[k] = v
            end
        end
        env.term.native = function() return contentWindow end
        env.term.current = function() return contentWindow end
        env.term.redirect = function(_target)
            return contentWindow
        end

        if window then
            env.window = {
                create = function(_parent, x, y, w, h, visible)
                    return window.create(contentWindow, x, y, w, h, visible)
                end,
            }
        end

        env.fs = vfs
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

        env.loadstring = loadstring
        env.load = load
        return env, nil
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

    local function createAppletSession(luaSource, sourceUrl, _mode, contentWindow)
        local sessionId = nextSessionId()
        local env, envErr = buildSandboxEnv(contentWindow, sourceUrl, sessionId)
        if not env then
            return nil, tostring(envErr or "Could not create sandbox environment")
        end
        installEventBridge(env)

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
            mode = "sandboxed",
            sessionId = sessionId,
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
