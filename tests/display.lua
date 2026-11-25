local createGraphics = dofile("app/display/graphics.lua")
local createManager = dofile("app/display/manager.lua")
local theme = dofile("app/display/chrome.lua")
local drawStart = dofile("app/display/start_page.lua")

colors = {black = 32768, white = 1, packRGB = function() return 0 end}

local presented, blits, richRows, scopeClosed, disposed = 0, 0, 0, 0, 0
local lastOptions, canvas, activeScreen, terminalRedirect
local legacy = false
local blanks = string.rep(" ", 64)
local digits = string.rep("f", 64)
local function window(_, _, _, columns, rows, visible)
    assert(visible == false)
    return {
        getLine = function(row)
            assert(row <= rows)
            return blanks:sub(1, columns), digits:sub(1, columns), digits:sub(1, columns)
        end,
        getPaletteColor = function() return 0, 0, 0 end,
        getCursorBlink = function() return false end,
        reposition = function(_, _, w, h) columns, rows = w, h end,
    }
end
local function noop() end

local native = {
    getPaletteColor = function() return 0, 0, 0 end,
    setCursorBlink = noop, setBackgroundColor = noop, setTextColor = noop,
    clear = noop, setCursorPos = noop,
}

local function newSurface()
    return {
        fillRect = noop, clear = noop, fillCircle = noop, circle = noop,
        rect = noop, line = noop, pixel = noop, polyline = noop, polygon = noop,
        setClip = noop, resetClip = noop, text = noop, richText = function(_, _, runs)
            assert(#runs > 0)
            richRows = richRows + 1
        end,
        setPaletteColor = noop,
    }
end

local api = {
    isSupported = function(target) return target ~= "unavailable" end,
    getCapabilities = function(target)
        return { kind = target == "left" and "monitor" or "computer", width = 120, height = 100 }
    end,
    open = function(_, options)
        lastOptions = options
        local screen = newSurface()
        local open = true
        screen.getSize = function() return options.width, options.height end
        screen.isOpen = function() return open end
        screen.close = function() open = false; scopeClosed = scopeClosed + 1 end
        screen.present = function() presented = presented + 1 end
        screen.createCanvas = function()
            canvas = newSurface()
            canvas.dispose = function() disposed = disposed + 1 end
            return canvas
        end
        screen.drawCanvas = function(layer, _, _, paint)
            assert(layer == canvas and paint.preserveIndexes)
        end
        if not legacy then
            screen.blitText = function(_, y, text, fg, bg, size)
                assert(y >= 36 and size == 12)
                assert(#text == #fg and #fg == #bg)
                blits = blits + 1
            end
        end
        screen.requestHostClipboard = function(operation)
            assert(operation == "read")
            return 17
        end
        activeScreen = screen
        return screen
    end,
}

local page = { history = {"about:home"}, historyIndex = 1, currentUrl = "about:blank" }
local state = {
    running = true, activeTab = 1, tabs = {page}, modal = {}, snackbar = {},
    ui = {
        closeBrowser = {x1 = 1, x2 = 1, y = 1}, tabs = {}, tabClose = {},
        newTab = {x1 = 62, x2 = 64, y = 1}, url = {x1 = 13, x2 = 61, y = 2},
        back = {x1 = 1, x2 = 3, y = 2}, forward = {x1 = 5, x2 = 7, y = 2},
        reload = {x1 = 9, x2 = 11, y = 2}, menuButton = {x1 = 62, x2 = 64, y = 2},
    },
}
local manager = createManager({
    core = { trim = function(text) return text end }, nativeTerm = native, colors = colors,
    term = {
        redirect = function(surface) terminalRedirect = surface end,
        current = function() return terminalRedirect end,
    },
    graphics = createGraphics(api, theme, drawStart, window, native),
    peripheral = {
        getNames = function() return {"left"} end,
        getType = function() return "monitor" end,
        wrap = function() return native end,
    },
    getState = function() return state end,
    currentDefaultBackgroundColorValue = function() return colors.black end,
    currentDefaultForegroundColorValue = function() return colors.white end,
})

assert(manager.applyDisplayTarget("internal"))
assert(terminalRedirect ~= native and lastOptions.scaling == "fit")
manager.drawGraphics(state, page)
assert(blits > 0 and presented == 1)
manager.drawGraphics(state, page)
assert(presented == 1, "an idle frame was published again")
assert(manager.translateEvent({"mouse_click", 1, 12, 12}) == nil)
local input = manager.translateEvent({"display_click", "native", 1, 112, 24})
assert(input[1] == "mouse_click" and input[3] == 15 and input[4] == 2)
input = manager.translateEvent({"display_click", "native", 1, 112, 36})
assert(input[4] == 3)
page.currentUrl, page.document = "about:home", {}
manager.drawGraphics(state, page)
input = manager.translateEvent({"display_click", "native", 1, 200, 150})
assert(input[1] == "browser_start_action" and input[2] == "address")
input = manager.translateEvent({"display_click", "native", 1, 280, 185})
assert(input[1] == "browser_start_action" and input[2] == "about:settings")
assert(manager.translateEvent({"display_click", "native", 1, 0, 220}) == nil)

local received
assert(manager.requestHostClipboard("read", nil, function(status, content)
    assert(status == "ok")
    received = content
end))
assert(not manager.requestHostClipboard("read", nil, noop))
manager.translateEvent({"display_clipboard", "native", 16, "ok", "unrelated"})
assert(received == nil)
manager.translateEvent({"display_clipboard", "native", 17, "ok", "approved"})
assert(received == "approved")

legacy = true
assert(manager.applyDisplayTarget("left"))
assert(lastOptions.scaling == "stretch" and scopeClosed == 1 and disposed == 1)
page.currentUrl = "about:blank"
manager.drawGraphics(state, page)
assert(richRows > 1, "legacy mod must draw the content and address")
assert(manager.translateEvent({"monitor_touch", "left", 9, 10}) == nil)
input = manager.translateEvent({"display_touch", "left", 9, 10})
assert(input[1] == "mouse_click" and input[3] == 2 and input[4] == 1 and input[5] == "monitor_touch")
assert(manager.translateEvent({"mouse_click", 1, 4, 6})[5] == nil, "native monitor controls lost")
assert(not manager.requestHostClipboard("read", nil, noop), "monitor must not request host clipboard")
assert(manager.applyDisplayTarget("internal"))
activeScreen.close()
assert(manager.translateEvent({"display_closed", "native", "force_exit"}) == nil and not state.running)
manager.setTextOnly(true)
assert(manager.applyDisplayTarget("internal") and terminalRedirect == native)
assert(manager.translateEvent({"mouse_click", 1, 12, 12})[1] == "mouse_click")

local noMod = createGraphics(nil, theme, drawStart, window, native)
assert(not noMod.open("native") and not noMod.supportsImages() and not noMod.isOpen())

local core = dofile("lib/core.lua")
local network = dofile("lib/network.lua")(core, {aboutPagesDir = "about-pages"})
local reads, closed = 0, false
http = {
    get = function(_, _, binary)
        assert(binary)
        return {
            read = function(count)
                reads = reads + 1
                if reads == 1 then
                    assert(count == #core.pngSignature)
                    return core.pngSignature
                end
                assert(count == core.pngPreviewLimit - #core.pngSignature + 1)
                return string.rep("x", count)
            end,
            readAll = function() error("PNG preview must use bounded reads") end,
            close = function() closed = true end,
        }
    end,
}
local imageBytes = network.fetchTextResource("https://example.test/image", false, {previewPng = true})
assert(#imageBytes == core.pngPreviewLimit + 1 and reads == 2 and closed)
print("Browser display tests passed")
