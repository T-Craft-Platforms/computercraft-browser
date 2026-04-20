-- sandbox.lua: Lua applet execution with sandboxed or full-access modes
-- Applet output is restricted to a content-area window object.

return function(deps)
    local core = deps.core
    local SCRIPT_DIR = deps.scriptDir or "/src/browser"
    local VFS_ROOT = deps.vfsRoot or "/.vfs"

    local trim = core.trim

    -- Virtual filesystem: all reads/writes go under VFS_ROOT
    local function createVirtualFs()
        if not fs.exists(VFS_ROOT) then
            fs.makeDir(VFS_ROOT)
        end

        local vfs = {}

        local function resolve(path)
            local cleaned = tostring(path or "")
            cleaned = cleaned:gsub("\\", "/")
            -- Use fs.combine to normalize the path, then verify it stays within VFS_ROOT
            local combined = fs.combine(VFS_ROOT, cleaned)
            -- Ensure the resolved path starts with VFS_ROOT to prevent traversal
            local normalizedRoot = fs.combine(VFS_ROOT, "")
            if combined:sub(1, #normalizedRoot) ~= normalizedRoot then
                return fs.combine(VFS_ROOT, "blocked")
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
            return fs.list(resolved)
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
        local vfs = createVirtualFs()

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
            sleep = os.sleep,
            startTimer = os.startTimer,
            cancelTimer = os.cancelTimer,
            setAlarm = os.setAlarm,
            cancelAlarm = os.cancelAlarm,
            queueEvent = os.queueEvent,
            pullEvent = os.pullEvent,
            pullEventRaw = os.pullEventRaw,
        }
        if sleep then
            env.sleep = sleep
        end

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

    -- Execute a Lua applet within the content window area.
    -- mode: "sandboxed" or "full"
    -- Returns: ok (boolean), error message (string or nil)
    local function executeApplet(luaSource, sourceUrl, mode, contentWindow)
        local env
        if mode == "sandboxed" then
            env = buildSandboxEnv(contentWindow, luaSource, sourceUrl)
        else
            env = buildFullAccessEnv(contentWindow, luaSource, sourceUrl)
        end

        local fn, compileErr = load(luaSource, "=" .. (sourceUrl or "applet"), "t", env)
        if not fn then
            return false, "Compile error: " .. tostring(compileErr)
        end

        local ok, runtimeErr = pcall(fn)
        if not ok then
            return false, "Runtime error: " .. tostring(runtimeErr)
        end

        return true, nil
    end

    return {
        executeApplet = executeApplet,
        createVirtualFs = createVirtualFs,
    }
end
