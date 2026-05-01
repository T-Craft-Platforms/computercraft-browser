-- security_scan.lua  v2
-- Defensive isolation scanner for CC: Tweaked / ComputerCraft runtimes.
-- Passive checks run automatically; active probes are triggered manually.

-- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
--  REPORT STRUCTURE
-- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

local REPORT = {
    startedAt = os.epoch and os.epoch("utc") or nil,
    computer  = {},
    environment = {},
    findings  = {},
    summary   = { passed = 0, failed = 0, warnings = 0, info = 0 }
}

local function addFinding(name, status, details)
    local entry = { name = name, status = status, details = details or "" }
    REPORT.findings[#REPORT.findings + 1] = entry
    local k = ({ PASS="passed", FAIL="failed", WARN="warnings", INFO="info" })[status]
    if k then REPORT.summary[k] = REPORT.summary[k] + 1 end
    return entry
end

-- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
--  SAFE CALL HELPERS
-- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

local function safeCall(fn, ...)
    local args = table.pack(...)
    return pcall(function() return fn(table.unpack(args, 1, args.n)) end)
end

local function tryDelete(path)
    return safeCall(fs.delete, path)
end

local function tryWriteFile(path, content)
    local ok, h = safeCall(fs.open, path, "w")
    if not ok or not h then return false, tostring(h) end
    local ok2, err = safeCall(function() h.write(content) h.close() end)
    if not ok2 then return false, tostring(err) end
    return true, nil
end

local function tryReadFile(path)
    local ok, h = safeCall(fs.open, path, "r")
    if not ok or not h then return false, nil, tostring(h) end
    local ok2, data = safeCall(function() local c = h.readAll() h.close() return c end)
    if not ok2 then return false, nil, tostring(data) end
    return true, data, nil
end

local function testPathWrite(path)
    local content = "security_scan_test=" .. tostring(math.random(100000, 999999))
    local wrote, wErr = tryWriteFile(path, content)
    if not wrote then return { ok = false, stage = "write", error = wErr } end
    local rOk, rContent, rErr = tryReadFile(path)
    if not rOk then tryDelete(path) return { ok = false, stage = "read_back", error = rErr } end
    local dOk, dErr = tryDelete(path)
    return { ok = true, readBackMatches = (rContent == content), deleteOk = dOk, deleteErr = dErr }
end

-- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
--  PASSIVE SCAN
-- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

local function collectComputerInfo()
    local t = REPORT.computer
    t.id      = os.getComputerID   and os.getComputerID()   or nil
    t.label   = os.getComputerLabel and os.getComputerLabel() or nil
    t.version = os.version          and os.version()          or nil
    if term and term.getSize then
        t.termWidth, t.termHeight = term.getSize()
    end
    if shell then
        t.runningProgram  = shell.getRunningProgram and shell.getRunningProgram() or nil
        t.workingDirectory = shell.dir              and shell.dir()               or nil
    end
end

local function collectEnvironmentInfo()
    local e = REPORT.environment
    e.hasFs         = fs         ~= nil
    e.hasShell      = shell      ~= nil
    e.hasPeripheral = peripheral ~= nil
    e.hasHttp       = http       ~= nil
    e.hasCommands   = commands   ~= nil
    e.hasMultishell = multishell ~= nil
    e.hasTerm       = term       ~= nil
    e.hasDebug      = debug      ~= nil
    e.hasIo         = io         ~= nil
    e.hasPackage    = package    ~= nil
    if peripheral and peripheral.getNames then
        local ok, names = safeCall(peripheral.getNames)
        e.peripherals = (ok and type(names) == "table") and names or {}
    else
        e.peripherals = {}
    end
end

local function testRootVisibility()
    local rexOk, rex = safeCall(fs.exists, "/")
    local lstOk, lst = safeCall(fs.list,   "/")
    local drvOk, drv = safeCall(fs.getDrive, "/")
    local roOk,  ro  = safeCall(fs.isReadOnly, "/")
    addFinding("Root path visible",        rexOk and rex  and "FAIL" or "PASS",
        "fs.exists('/') => " .. tostring(rex))
    addFinding("Root listing allowed",     lstOk           and "FAIL" or "PASS",
        lstOk and "fs.list('/') succeeded" or ("fs.list('/') failed: " .. tostring(lst)))
    addFinding("Root mount exposure",      drvOk           and "WARN" or "PASS",
        "fs.getDrive('/') => " .. tostring(drv))
    addFinding("Root read-only exposed",   roOk            and "WARN" or "PASS",
        "fs.isReadOnly('/') => " .. tostring(ro))
end

local function testKnownMounts()
    for _, path in ipairs({ "/", "rom", "rom/", "disk", "disk/" }) do
        local ok, val = safeCall(fs.exists, path)
        addFinding("Path exposure: " .. path,
            (ok and val) and "WARN" or "PASS",
            "fs.exists('" .. path .. "') => " .. tostring(val))
    end
end

local function testWrites()
    local paths = {
        { p = "/security_scan_tmp.txt",     base = true  },
        { p = "security_scan_tmp.txt",      base = false },
        { p = "tmp/security_scan_tmp.txt",  base = false },
        { p = "rom/security_scan_tmp.txt",  base = false, rom = true },
    }
    for _, item in ipairs(paths) do
        local r = testPathWrite(item.p)
        if r.ok then
            local status = item.rom and "WARN" or "FAIL"
            addFinding("Writable path: " .. item.p, status,
                "Write succeeded, readBack=" .. tostring(r.readBackMatches) ..
                ", deleteOk=" .. tostring(r.deleteOk))
        else
            addFinding("Writable path: " .. item.p, "PASS",
                "Blocked at " .. tostring(r.stage) .. ": " .. tostring(r.error))
        end
    end
end

local function testDirectoryCreation()
    local paths = {
        { p = "/security_scan_dir",        rom = false },
        { p = "security_scan_dir",         rom = false },
        { p = "tmp/security_scan_dir",     rom = false },
        { p = "rom/security_scan_dir",     rom = true  },
    }
    for _, item in ipairs(paths) do
        local ok, err = safeCall(fs.makeDir, item.p)
        if ok then
            local dOk, dErr = tryDelete(item.p)
            addFinding("Directory creation: " .. item.p, item.rom and "WARN" or "FAIL",
                "makeDir succeeded, deleteOk=" .. tostring(dOk))
        else
            addFinding("Directory creation: " .. item.p, "PASS",
                "makeDir blocked: " .. tostring(err))
        end
    end
end

local function testSystemDetailsExposure()
    local c = REPORT.computer
    addFinding("Computer ID exposed",    c.id      ~= nil and "WARN" or "PASS",
        "os.getComputerID() => " .. tostring(c.id))
    addFinding("Computer label exposed", c.label   ~= nil and "WARN" or "PASS",
        "os.getComputerLabel() => " .. tostring(c.label))
    addFinding("OS version exposed",     c.version ~= nil and "WARN" or "PASS",
        "os.version() => " .. tostring(c.version))
end

local function testApiExposure()
    local e = REPORT.environment
    local risky = {
        { key = "hasHttp",       label = "HTTP API exposed"         },
        { key = "hasCommands",   label = "Commands API exposed"     },
        { key = "hasDebug",      label = "debug library exposed"    },
        { key = "hasIo",         label = "io library exposed"       },
        { key = "hasPackage",    label = "package library exposed"  },
        { key = "hasPeripheral", label = "peripheral API exposed"   },
    }
    for _, item in ipairs(risky) do
        addFinding(item.label, e[item.key] and "WARN" or "PASS",
            e[item.key] and "Available in environment" or "Not available")
    end
end

local function runPassiveScan()
    math.randomseed((os.epoch and os.epoch("utc")) or os.time())
    collectComputerInfo()
    collectEnvironmentInfo()
    testRootVisibility()
    testKnownMounts()
    testWrites()
    testDirectoryCreation()
    testSystemDetailsExposure()
    testApiExposure()
end

-- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
--  ACTIVE PROBES  (each returns a finding-like table)
-- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

local probeResults = {}   -- list of { label, status, detail }

local function recordProbe(label, status, detail)
    local entry = { label = label, status = status, detail = detail or "" }
    probeResults[#probeResults + 1] = entry
    return entry
end

-- 1. Create a file in several locations
local function probeCreateFile()
    local targets = {
        "probe_create.txt",
        "/probe_create.txt",
        "rom/probe_create.txt",
    }
    local any = false
    local details = {}
    for _, path in ipairs(targets) do
        local ok, err = tryWriteFile(path, "probe")
        if ok then
            any = true
            details[#details+1] = path .. " => CREATED"
            tryDelete(path)
        else
            details[#details+1] = path .. " => blocked"
        end
    end
    recordProbe("Create file", any and "FAIL" or "PASS", table.concat(details, " | "))
end

-- 2. Modify an existing file (startup or any writable file)
local function probeModifyFile()
    local targets = { "startup.lua", "startup", "disk/startup.lua" }
    local any = false
    local details = {}
    for _, path in ipairs(targets) do
        -- read original
        local rOk, original = tryReadFile(path)
        -- attempt to append
        local ok, h = safeCall(fs.open, path, "a")
        if ok and h then
            any = true
            local wOk, wErr = safeCall(function()
                h.write("\n-- probe_modify")
                h.close()
            end)
            -- restore
            if rOk and original ~= nil then
                tryWriteFile(path, original)
            end
            details[#details+1] = path .. " => MODIFIED"
        else
            details[#details+1] = path .. " => blocked"
        end
    end
    recordProbe("Modify file", any and "FAIL" or "PASS", table.concat(details, " | "))
end

-- 3. Read /rom
local function probeReadRom()
    local paths = { "rom/", "rom/startup.lua", "rom/programs/shell.lua", "rom/apis/fs.lua" }
    local any = false
    local details = {}
    for _, path in ipairs(paths) do
        local existOk, exists = safeCall(fs.exists, path)
        if existOk and exists then
            any = true
            local rOk, content = tryReadFile(path)
            if rOk and content then
                details[#details+1] = path .. " => READ (" .. #content .. " bytes)"
            else
                local lOk, list = safeCall(fs.list, path)
                if lOk and list then
                    details[#details+1] = path .. " => LISTED (" .. #list .. " entries)"
                else
                    details[#details+1] = path .. " => EXISTS but unreadable"
                end
            end
        else
            details[#details+1] = path .. " => not found"
        end
    end
    recordProbe("Read /rom", any and "WARN" or "PASS", table.concat(details, " | "))
end

-- 4. Try to exit the system (shell.exit / error to shell)
local function probeExitSystem()
    local attempts = {}

    -- Try shell.exit()
    if shell and shell.exit then
        local ok, err = safeCall(shell.exit)
        attempts[#attempts+1] = "shell.exit() => " .. (ok and "called" or "blocked: " .. tostring(err))
    else
        attempts[#attempts+1] = "shell.exit => not available"
    end

    -- Try os.shutdown (deferred, so we just test if it exists/callable)
    if os.shutdown then
        attempts[#attempts+1] = "os.shutdown => present (see shutdown probe)"
    else
        attempts[#attempts+1] = "os.shutdown => not present"
    end

    -- Try error() to crash shell
    -- We wrap in pcall so it won't actually kill us
    local ok, err = pcall(function()
        -- intentional error to see if it propagates up
        if false then error("probe_exit") end
    end)

    recordProbe("Exit system", "INFO", table.concat(attempts, " | "))
end

-- 5. Shutdown / reboot system
local function probeShutdown()
    local attempts = {}
    if os.shutdown then
        attempts[#attempts+1] = "os.shutdown => present (would shut down if called!)"
        -- We deliberately DO NOT call it; just report presence
    else
        attempts[#attempts+1] = "os.shutdown => not present (PASS)"
    end
    if os.reboot then
        attempts[#attempts+1] = "os.reboot => present (would reboot if called!)"
    else
        attempts[#attempts+1] = "os.reboot => not present (PASS)"
    end

    local hasShutdown = os.shutdown ~= nil
    local hasReboot   = os.reboot   ~= nil
    recordProbe("Shutdown/Reboot API", (hasShutdown or hasReboot) and "WARN" or "PASS",
        table.concat(attempts, " | "))
end

-- 6. Change default startup application
local function probeChangeStartup()
    local targets = { "startup.lua", "startup", "/startup.lua", "/startup" }
    local any = false
    local details = {}
    for _, path in ipairs(targets) do
        local ok, err = tryWriteFile(path, '-- probe startup hijack\nprint("HIJACKED")')
        if ok then
            any = true
            details[#details+1] = path .. " => WRITTEN (startup hijack possible!)"
            tryDelete(path)
        else
            details[#details+1] = path .. " => blocked"
        end
    end
    recordProbe("Change startup app", any and "FAIL" or "PASS", table.concat(details, " | "))
end

-- 7. Crash the system (infinite loop / stack overflow in pcall, or error storm)
local function probeCrash()
    local attempts = {}

    -- Stack overflow attempt (sandboxed in pcall)
    local ok1, err1 = pcall(function()
        local function recurse() return recurse() end
        recurse()
    end)
    attempts[#attempts+1] = "Stack overflow: " .. (ok1 and "not caught" or "caught by pcall: " .. tostring(err1):sub(1,40))

    -- Attempt to raise an unhandled error
    local ok2, err2 = pcall(error, "probe_crash_error", 0)
    attempts[#attempts+1] = "error(): " .. (ok2 and "swallowed" or "caught: " .. tostring(err2):sub(1,40))

    -- Attempt to corrupt a global
    local ok3, err3 = pcall(function()
        local _old = os.clock
        os.clock = nil  -- try to remove a global
        os.clock = _old
    end)
    attempts[#attempts+1] = "Corrupt global: " .. (ok3 and "succeeded (writable globals!)" or "blocked: " .. tostring(err3):sub(1,30))

    local corrupted = ok3
    recordProbe("Crash system", corrupted and "WARN" or "PASS", table.concat(attempts, " | "))
end

-- 8. Set entire terminal background to white
local function probeBackgroundWhite()
    if not (term and term.getSize) then
        recordProbe("Background to white", "INFO", "term API not available")
        return
    end

    local w, h = term.getSize()
    local hasColor = term.isColour and term.isColour()

    if not hasColor then
        recordProbe("Background to white", "INFO", "No colour support; painting with spaces anyway")
    end

    -- Try native term
    local ok1, err1 = pcall(function()
        if hasColor then
            term.setBackgroundColor(colours.white)
            term.setTextColor(colours.black)
        end
        term.clear()
        for y = 1, h do
            term.setCursorPos(1, y)
            term.write(string.rep(" ", w))
        end
    end)

    -- Also try native window / redirect if available
    local ok2 = false
    if window and window.create then
        local okW, win = pcall(window.create, term.native and term.native() or term, 1, 1, w, h, true)
        if okW and win then
            ok2 = true
        end
    end

    -- Restore immediately
    pcall(function()
        if hasColor then
            term.setBackgroundColor(colours.black)
            term.setTextColor(colours.white)
        end
        term.clear()
    end)

    recordProbe("Background to white", ok1 and "WARN" or "PASS",
        ok1 and ("Painted " .. w .. "x" .. h .. " terminal white (then restored)")
             or ("term.clear blocked: " .. tostring(err1)))
end

-- 9. Print via printer peripheral
local function probePrinter()
    local results = {}

    if not peripheral then
        recordProbe("Use printer", "INFO", "peripheral API not available")
        return
    end

    local ok, names = safeCall(peripheral.getNames)
    if not ok or type(names) ~= "table" then
        recordProbe("Use printer", "INFO", "peripheral.getNames() failed")
        return
    end

    local printerFound = false
    for _, name in ipairs(names) do
        local typeOk, pType = safeCall(peripheral.getType, name)
        if typeOk and pType == "printer" then
            printerFound = true
            local wrapOk, printer = safeCall(peripheral.wrap, name)
            if wrapOk and printer then
                -- Try to start a new page
                local npOk, npErr = safeCall(function() return printer.newPage() end)
                if npOk and npErr then
                    -- Write a line
                    local wlOk = safeCall(function() printer.write("SECURITY PROBE") end)
                    local epOk = safeCall(function() return printer.endPage() end)
                    results[#results+1] = name .. " => PAGE PRINTED (newPage=" ..
                        tostring(npErr) .. ", write=" .. tostring(wlOk) .. ", endPage=" .. tostring(epOk) .. ")"
                else
                    results[#results+1] = name .. " => newPage failed: " .. tostring(npErr)
                end
            else
                results[#results+1] = name .. " => wrap failed"
            end
        end
    end

    if not printerFound then
        results[#results+1] = "No printer peripheral found"
    end

    local printed = #results > 0 and results[1]:find("PAGE PRINTED") ~= nil
    recordProbe("Use printer", printed and "WARN" or "INFO", table.concat(results, " | "))
end

-- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
--  PROBE DEFINITIONS  (shown as buttons)
-- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

local PROBES = {
    { label = "Create files",        fn = probeCreateFile     },
    { label = "Modify files",        fn = probeModifyFile     },
    { label = "Read /rom",           fn = probeReadRom        },
    { label = "Exit system",         fn = probeExitSystem     },
    { label = "Shutdown/Reboot API", fn = probeShutdown       },
    { label = "Change startup app",  fn = probeChangeStartup  },
    { label = "Crash system",        fn = probeCrash          },
    { label = "BG to white",         fn = probeBackgroundWhite},
    { label = "Print via printer",   fn = probePrinter        },
}

-- Track which probes have been run
local probeRan = {}

-- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
--  UI STATE
-- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

local PAGE_REPORT  = 1
local PAGE_PROBES  = 2
local currentPage  = PAGE_REPORT

local reportLines  = {}
local scrollOffset = 0

local buttons = {}   -- list of { x1,y1,x2,y2, action }

-- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
--  REPORT LINE BUILDER
-- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

local function pushLine(t, text)
    t[#t + 1] = tostring(text or "")
end

local function buildReportLines()
    local t = {}

    pushLine(t, "Security Scan Report")
    pushLine(t, string.rep("=", 40))
    pushLine(t, "")
    pushLine(t, "SYSTEM")
    pushLine(t, "  ID:      " .. tostring(REPORT.computer.id))
    pushLine(t, "  Label:   " .. tostring(REPORT.computer.label))
    pushLine(t, "  Version: " .. tostring(REPORT.computer.version))
    pushLine(t, "  Term:    " .. tostring(REPORT.computer.termWidth) .. "x" .. tostring(REPORT.computer.termHeight))
    pushLine(t, "  CWD:     " .. tostring(REPORT.computer.workingDirectory))
    pushLine(t, "  Program: " .. tostring(REPORT.computer.runningProgram))
    pushLine(t, "")
    pushLine(t, "ENVIRONMENT")
    local eKeys = { "hasFs","hasShell","hasPeripheral","hasHttp","hasCommands",
                    "hasMultishell","hasTerm","hasDebug","hasIo","hasPackage" }
    for _, k in ipairs(eKeys) do
        pushLine(t, ("  %-14s: %s"):format(k, tostring(REPORT.environment[k])))
    end
    pushLine(t, "")
    local perifs = REPORT.environment.peripherals or {}
    pushLine(t, "  Peripherals: " .. #perifs)
    for i, n in ipairs(perifs) do pushLine(t, "    [" .. i .. "] " .. n) end
    pushLine(t, "")
    pushLine(t, "PASSIVE FINDINGS")
    for i, f in ipairs(REPORT.findings) do
        pushLine(t, ("  [%02d] [%-4s] %s"):format(i, f.status, f.name))
        if f.details ~= "" then
            pushLine(t, "        " .. f.details)
        end
    end
    pushLine(t, "")
    pushLine(t, "SUMMARY")
    pushLine(t, "  Passed:   " .. REPORT.summary.passed)
    pushLine(t, "  Failed:   " .. REPORT.summary.failed)
    pushLine(t, "  Warnings: " .. REPORT.summary.warnings)
    pushLine(t, "  Info:     " .. REPORT.summary.info)
    pushLine(t, "")
    if REPORT.summary.failed == 0 then
        pushLine(t, "Result: no direct isolation breaks found in passive scan.")
    else
        pushLine(t, "Result: one or more isolation breaks detected!")
    end

    -- Active probe results
    if #probeResults > 0 then
        pushLine(t, "")
        pushLine(t, "ACTIVE PROBE RESULTS")
        for _, pr in ipairs(probeResults) do
            pushLine(t, ("  [%-4s] %s"):format(pr.status, pr.label))
            if pr.detail ~= "" then
                -- wrap long detail lines at ~50 chars
                local d = pr.detail
                while #d > 0 do
                    pushLine(t, "        " .. d:sub(1, 60))
                    d = d:sub(61)
                end
            end
        end
    end

    reportLines = t
end

-- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
--  COLOUR HELPERS
-- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

local function isColour()
    return term.isColour and term.isColour()
end

local function setNormal()
    if isColour() then
        term.setBackgroundColor(colours.black)
        term.setTextColor(colours.white)
    end
end

local function setColour(bg, fg)
    if isColour() then
        term.setBackgroundColor(bg)
        term.setTextColor(fg)
    end
end

local function statusColour(status)
    if not isColour() then return end
    if     status == "PASS" then term.setTextColor(colours.lime)
    elseif status == "FAIL" then term.setTextColor(colours.red)
    elseif status == "WARN" then term.setTextColor(colours.yellow)
    elseif status == "INFO" then term.setTextColor(colours.cyan)
    end
end

-- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
--  RENDER
-- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

local function clearButtons()
    buttons = {}
end

local function addButton(x1, y, label, action, bgC, fgC)
    local x2 = x1 + #label - 1
    buttons[#buttons + 1] = { x1=x1, y1=y, x2=x2, y2=y, action=action }
    term.setCursorPos(x1, y)
    if isColour() then
        term.setBackgroundColor(bgC or colours.grey)
        term.setTextColor(fgC or colours.white)
    end
    term.write(label)
    setNormal()
    return x2 + 2   -- next x position (with 1 space gap)
end

local function drawHeader(w)
    term.setCursorPos(1, 1)
    setColour(colours.blue, colours.white)
    term.clearLine()
    local title = " Security Scan v2  "
    term.write(title)
    -- tabs
    local tabX = #title + 2
    term.setCursorPos(tabX, 1)
    if currentPage == PAGE_REPORT then
        setColour(colours.white, colours.black)
        term.write("[Report]")
        setColour(colours.blue, colours.white)
        term.write(" ")
        setColour(isColour() and colours.lightGrey or colours.white, colours.black)
        term.write("[Probes]")
    else
        setColour(isColour() and colours.lightGrey or colours.white, colours.black)
        term.write("[Report]")
        setColour(colours.blue, colours.white)
        term.write(" ")
        setColour(colours.white, colours.black)
        term.write("[Probes]")
    end
    -- register tab buttons
    buttons[#buttons + 1] = { x1=tabX, y1=1, x2=tabX+7, y2=1, action="tab_report" }
    buttons[#buttons + 1] = { x1=tabX+9, y1=1, x2=tabX+16, y2=1, action="tab_probes" }

    setNormal()
end

local function drawFooter(w, h)
    term.setCursorPos(1, h)
    setColour(isColour() and colours.grey or colours.black, colours.white)
    term.clearLine()
    local hint = " Scroll: mouse/arrows | Q: quit"
    term.write(hint:sub(1, w - 10))
    -- Exit button
    local exitLabel = "[ Exit ]"
    local bx = w - #exitLabel + 1
    term.setCursorPos(bx, h)
    setColour(colours.red, colours.white)
    term.write(exitLabel)
    buttons[#buttons + 1] = { x1=bx, y1=h, x2=w, y2=h, action="exit" }
    setNormal()
end

local function drawReportPage(w, h)
    local bodyTop    = 2
    local bodyBottom = h - 1
    local bodyH      = bodyBottom - bodyTop + 1
    local maxScroll  = math.max(0, #reportLines - bodyH)
    scrollOffset = math.max(0, math.min(scrollOffset, maxScroll))

    for row = bodyTop, bodyBottom do
        term.setCursorPos(1, row)
        term.clearLine()
        local idx = scrollOffset + (row - bodyTop) + 1
        local line = reportLines[idx]
        if line then
            -- Colour-code status tags
            local tag = line:match("%[(%u+)%]")
            if tag then
                setNormal()
                term.write(line:sub(1, line:find("%[" .. tag .. "%]") - 1))
                statusColour(tag)
                term.write("[" .. tag .. "]")
                setNormal()
                local after = line:sub(line:find("%[" .. tag .. "%]") + #tag + 2)
                term.write(after:sub(1, w))
            else
                setNormal()
                term.write(line:sub(1, w))
            end
        end
    end
end

-- probe page layout
local PROBE_COL_W = 22   -- button width including padding

local function drawProbePage(w, h)
    local bodyTop    = 2
    local bodyBottom = h - 1

    -- Title row
    term.setCursorPos(1, bodyTop)
    setColour(isColour() and colours.grey or colours.black, colours.white)
    term.clearLine()
    term.write("  Active Probes  (click to run â€” all wrapped in pcall)")
    setNormal()

    -- Draw probe buttons in a 2-column grid
    local cols = math.max(1, math.floor(w / (PROBE_COL_W + 2)))
    local startY = bodyTop + 2

    for i, probe in ipairs(PROBES) do
        local col = (i - 1) % cols
        local row = math.floor((i - 1) / cols)
        local x   = col * (PROBE_COL_W + 2) + 1
        local y   = startY + row * 2

        if y <= bodyBottom - 1 then
            term.setCursorPos(x, y)
            -- Determine button colour based on ran/result
            local bg  = isColour() and colours.grey or colours.black
            local fg  = colours.white
            local ran = probeRan[i]
            if ran then
                local pr = probeResults[ran]
                if pr then
                    if     pr.status == "FAIL" then bg = colours.red
                    elseif pr.status == "WARN" then bg = colours.orange
                    elseif pr.status == "PASS" then bg = colours.green
                    else                             bg = colours.blue
                    end
                end
            end

            local btnLabel = (" %-" .. (PROBE_COL_W - 2) .. "s "):format(probe.label:sub(1, PROBE_COL_W - 2))
            term.setCursorPos(x, y)
            setColour(bg, fg)
            term.write(btnLabel:sub(1, PROBE_COL_W))
            buttons[#buttons + 1] = { x1=x, y1=y, x2=x+PROBE_COL_W-1, y2=y, action="probe_" .. i }

            -- Result line below button
            term.setCursorPos(x, y + 1)
            setNormal()
            term.clearLine()
            if ran then
                local pr = probeResults[ran]
                if pr then
                    statusColour(pr.status)
                    local short = pr.detail:sub(1, PROBE_COL_W)
                    term.write(short)
                    setNormal()
                end
            else
                setColour(isColour() and colours.grey or colours.black, isColour() and colours.lightGrey or colours.white)
                term.write(("not run"):sub(1, PROBE_COL_W))
                setNormal()
            end
        end
    end

    -- Instructions
    local instrY = bodyBottom
    term.setCursorPos(1, instrY)
    setNormal()
    term.clearLine()
    term.write("  Green=PASS  Orange=WARN  Red=FAIL  Blue=INFO  (go to Report for details)")
end

local function render()
    local w, h = term.getSize()
    clearButtons()
    setNormal()
    term.clear()
    drawHeader(w)
    if currentPage == PAGE_REPORT then
        drawReportPage(w, h)
    else
        drawProbePage(w, h)
    end
    drawFooter(w, h)
    term.setCursorPos(1, 1)
end

-- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
--  INPUT HANDLING
-- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

local function hitTest(x, y)
    for _, b in ipairs(buttons) do
        if x >= b.x1 and x <= b.x2 and y >= b.y1 and y <= b.y2 then
            return b.action
        end
    end
    return nil
end

local function runProbe(idx)
    local probe = PROBES[idx]
    if not probe then return end
    -- run wrapped
    local pok, perr = pcall(probe.fn)
    if not pok then
        recordProbe(probe.label, "INFO", "probe threw: " .. tostring(perr))
    end
    -- point probeRan[idx] to the new last probeResults entry
    probeRan[idx] = #probeResults
    buildReportLines()
end

local function handleAction(action)
    if action == "exit" then
        return true   -- signal to quit
    elseif action == "tab_report" then
        currentPage  = PAGE_REPORT
        scrollOffset = 0
    elseif action == "tab_probes" then
        currentPage = PAGE_PROBES
    elseif action:sub(1, 6) == "probe_" then
        local idx = tonumber(action:sub(7))
        if idx then runProbe(idx) end
    end
    return false
end

local function scroll(delta)
    if currentPage ~= PAGE_REPORT then return end
    local _, h = term.getSize()
    local bodyH = (h - 1) - 2 + 1
    local maxS  = math.max(0, #reportLines - bodyH)
    scrollOffset = math.max(0, math.min(scrollOffset + delta, maxS))
end

local function eventLoop()
    render()
    while true do
        local ev, p1, p2, p3 = os.pullEvent()

        if ev == "mouse_scroll" then
            scroll(p1)
            render()

        elseif ev == "mouse_click" then
            local _, x, y = p1, p2, p3
            local action = hitTest(x, y)
            if action then
                if handleAction(action) then break end
                render()
            end

        elseif ev == "key" then
            if p1 == keys.q then
                break
            elseif p1 == keys.up        then scroll(-1)  render()
            elseif p1 == keys.down      then scroll(1)   render()
            elseif p1 == keys.pageUp    then scroll(-10) render()
            elseif p1 == keys.pageDown  then scroll(10)  render()
            elseif p1 == keys.tab then
                currentPage = (currentPage == PAGE_REPORT) and PAGE_PROBES or PAGE_REPORT
                render()
            end

        elseif ev == "term_resize" then
            render()
        end
    end
end

local function cleanupScreen()
    setNormal()
    term.clear()
    term.setCursorPos(1, 1)
    print("Security scan complete.")
end

-- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
--  MAIN
-- â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

runPassiveScan()
buildReportLines()
eventLoop()
cleanupScreen()