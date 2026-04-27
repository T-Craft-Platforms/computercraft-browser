local APP_TITLE = "CC Browser"

local function getScriptDir()
    if shell and shell.getRunningProgram and fs and fs.getDir then
        local running = shell.getRunningProgram()
        if running and running ~= "" then
            if shell and type(shell.resolve) == "function" then
                local okResolve, resolved = pcall(shell.resolve, running)
                if okResolve and resolved and resolved ~= "" then
                    return fs.getDir(resolved)
                end
            end
            return fs.getDir(running)
        end
    end
    if shell and type(shell.dir) == "function" then
        local cwd = shell.dir()
        if cwd and cwd ~= "" then
            return cwd
        end
    end
    return "/src/browser"
end

local appPath = fs.combine(getScriptDir(), "app.lua")
if not fs.exists(appPath) then
    term.setCursorBlink(false)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.red)
    term.clear()
    term.setCursorPos(1, 1)
    print("Missing file: " .. appPath)
    return
end

local loadOk, runOrErr = pcall(dofile, appPath)
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
