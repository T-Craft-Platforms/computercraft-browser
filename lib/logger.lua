-- Verbose logger: appends timestamped entries to a log file.
-- Usage: local createLogger = loadModule("lib/logger.lua")
--        local logger = createLogger({ logPath = "/path/to/log.txt", isEnabled = fn })
return function(options)
    options = options or {}
    local logPath = tostring(options.logPath or "/log.txt")
    local isEnabled = options.isEnabled or function() return false end

    local function getTimestamp()
        if os and type(os.date) == "function" then
            local ok, t = pcall(os.date, "%Y-%m-%d %H:%M:%S")
            if ok and t then return tostring(t) end
        end
        if os and type(os.clock) == "function" then
            return ("t+%.3f"):format(os.clock())
        end
        return "?"
    end

    local function append(level, message)
        if not isEnabled() then return end
        if not (fs and fs.open) then return end
        local handle = fs.open(logPath, "a")
        if not handle then return end
        local line = ("[%s] [%s] %s\n"):format(getTimestamp(), level, tostring(message or ""))
        local ok = pcall(function() handle.write(line) end)
        if not ok then pcall(function() handle:write(line) end) end
        local okClose = pcall(function() handle.close() end)
        if not okClose then pcall(function() handle:close() end) end
    end

    return {
        info  = function(msg) append("INFO",  msg) end,
        warn  = function(msg) append("WARN",  msg) end,
        error = function(msg) append("ERROR", msg) end,
        io    = function(msg) append("IO",    msg) end,
    }
end
