local pointerEvents = {
    display_click = "mouse_click", display_drag = "mouse_drag",
    display_up = "mouse_up", display_scroll = "mouse_scroll",
}

local function utf8Terminal(text)
    return (text:gsub("[%z\r\n\128-\255]", function(character)
        local byte = character:byte()
        if byte < 128 then return " " end
        return string.char(192 + math.floor(byte / 64), 128 + byte % 64)
    end))
end

local function drawRow(screen, x, y, text, foreground, background, fontSize)
    if screen.blitText then
        screen.blitText(x, y, text, foreground, background, fontSize)
        return
    end
    local runs = {}
    local start = 1
    while start <= #text do
        local fg, bg = foreground:sub(start, start), background:sub(start, start)
        local finish = start
        while finish < #text and foreground:sub(finish + 1, finish + 1) == fg
            and background:sub(finish + 1, finish + 1) == bg do
            finish = finish + 1
        end
        runs[#runs + 1] = {
            text = utf8Terminal(text:sub(start, finish)), color = tonumber(fg, 16), background = tonumber(bg, 16),
        }
        start = finish + 1
    end
    screen.richText(x, y, runs, { size = fontSize })
end

return function(api, chrome, startPage, createWindow, nativeTerm)
    local screen, surface, target, layer, image, imageDocument
    local width, height, columns, rows, cellWidth, fontSize, contentWidth, chromeRowHeight
    local rowCache, chromeKey, cursor, paletteCache
    local scene, sceneKey, startActions, drawnTopRows

    local function releaseImage()
        if image then image.dispose() end
        image, imageDocument = nil, nil
    end

    local function close()
        if layer then layer.dispose() end
        releaseImage()
        if screen and screen.isOpen() then screen.close() end
        screen, surface, target, layer = nil, nil, nil, nil
    end

    local function geometry()
        width, height = screen.getSize()
        if not width then return false end
        fontSize = width >= 300 and height >= 120 and 12 or 9
        chromeRowHeight = fontSize + 6
        cellWidth = fontSize == 12 and 8 or 6
        columns, rows = math.floor(width / cellWidth), math.floor((height - 12) / fontSize)
        if columns < 24 or rows < 10 then return false end
        contentWidth = columns * cellWidth
        if surface then
            surface.reposition(1, 1, columns, rows)
        else
            surface = createWindow(nativeTerm, 1, 1, columns, rows, false)
        end
        if layer then layer.dispose() end
        layer = screen.createCanvas and screen.createCanvas(width, chromeRowHeight * 2, { transparent = false })
        rowCache, paletteCache, chromeKey, cursor = {}, {}, nil, nil
        scene, sceneKey, startActions, drawnTopRows = nil, nil, nil, nil
        chrome.applyPalette(screen)
        screen.clear(chrome.frame)
        return true
    end

    local function open(nextTarget)
        if not (api and api.isSupported and api.open and api.getCapabilities and createWindow)
            or not api.isSupported(nextTarget) then return nil end
        if target == nextTarget and screen.isOpen() then return surface end
        local cap = api.getCapabilities(nextTarget)
        if not cap then return nil end
        local options = { presentMode = "manual", scaling = "fit" }
        if cap.kind == "monitor" then
            local aspect = cap.width / math.max(1, cap.height)
            if aspect <= 0 then aspect = 1 end
            options.width = 480
            options.height = math.max(216, math.min(540, math.floor(options.width / aspect + 0.5)))
            options.scaling = "stretch"
        elseif cap.kind == "pocket" then
            options.width, options.height = 234, 270
        else
            options.width, options.height = 512, 300
        end
        close()
        local failure
        screen, failure = api.open(nextTarget, options)
        if not screen then return nil, failure end
        if not geometry() then
            close()
            return nil, { message = "The available graphics canvas is too small for the browser." }
        end
        target = nextTarget
        return surface
    end

    local function checkPalette(applet)
        local changed = false
        for index = 0, 15 do
            local r, g, b = (applet and surface or nativeTerm).getPaletteColor(2 ^ index)
            local rgb = colors.packRGB(r, g, b)
            if rgb ~= paletteCache[index] then
                screen.setPaletteColor(index, rgb)
                paletteCache[index] = rgb
                changed = true
            end
        end
        return changed
    end

    local function prepareImage(document)
        if imageDocument == document then return end
        releaseImage()
        imageDocument = document
        if not (document and document.browserPng and screen.loadImageBytes) then return end
        image = screen.loadImageBytes(document.browserPng)
        if image then
            for index, color in ipairs(api.generatePalette(image, 192) or {}) do
                screen.setPaletteColor(31 + index, color)
            end
        end
    end

    local function drawImage(y)
        local iw, ih = image.getSize()
        local areaHeight = height - y
        local scale = math.min((width - 16) / iw, (areaHeight - 16) / ih, 4)
        local fittedWidth, fittedHeight = math.max(1, math.floor(iw * scale)), math.max(1, math.floor(ih * scale))
        screen.fillRect(0, y, width, areaHeight, chrome.field)
        local imageX = math.floor((width - fittedWidth) / 2)
        local imageY = y + math.floor((areaHeight - fittedHeight) / 2)
        screen.rect(imageX - 1, imageY - 1, fittedWidth + 2, fittedHeight + 2, chrome.edge)
        screen.fillRect(imageX, imageY, fittedWidth, fittedHeight, chrome.toolbar)
        screen.drawImage(image, imageX, imageY, { width = fittedWidth, height = fittedHeight, dither = true })
    end

    local function draw(state, tab)
        if not (screen and screen.isOpen()) then return end
        local changed = checkPalette(tab.applet and tab.applet.running)
        local topRows = state.fullscreen and 0 or 2
        local topPixels = topRows * chromeRowHeight
        if drawnTopRows ~= topRows then
            screen.clear(chrome.frame)
            drawnTopRows, rowCache, chromeKey, scene, changed = topRows, {}, nil, nil, true
        end
        local useChrome = topRows > 0 and not state.modal.open
        local presentedCursor
        if surface.getCursorBlink() then
            local x, y = surface.getCursorPos()
            if x >= 1 and x <= columns and y >= 1 and y <= rows then presentedCursor = { x = x, y = y } end
        end

        local previousImage = image
        prepareImage(tab.document)
        local showScene = not (state.modal.open or state.menuOpen or tab.loading or state.snackbar.active)
        local nextScene, nextKey
        if showScene and image then
            nextScene, nextKey = "image", topRows
        elseif showScene and useChrome and not state.caretMode and tab.currentUrl == "about:home" and tab.document then
            nextScene, nextKey = "home", tab.urlFocus
        end
        local sceneChanged = scene ~= nextScene or sceneKey ~= nextKey
        if scene ~= nextScene then
            rowCache = {}
            startActions = nil
            if not nextScene then screen.fillRect(0, topPixels, width, height - topPixels, chrome.frame) end
            changed = true
        end
        scene, sceneKey = nextScene, nextKey
        if scene == "image" and (sceneChanged or image ~= previousImage or changed) then
            drawImage(topPixels)
            changed = true
        elseif scene == "home" and sceneChanged then
            startActions = startPage(screen, chrome, width, height, cellWidth, fontSize, topPixels, tab.urlFocus)
            changed = true
        end

        if useChrome then
            local tabsText, tabsFg, tabsBg = surface.getLine(1)
            local url, urlFg, urlBg = surface.getLine(2)
            local key = table.concat({
                tabsText, tabsFg, tabsBg, url, urlFg, urlBg,
                state.activeTab, tab.historyIndex, #tab.history, tostring(tab.loading), tostring(state.menuOpen),
                tostring(tab.urlFocus), tostring(state.expandedTabIndex),
            }, "\0")
            if key ~= chromeKey then
                chrome.draw(layer or screen, width, cellWidth, chromeRowHeight, fontSize,
                    tabsText, url, urlBg, state, utf8Terminal)
                if layer then screen.drawCanvas(layer, 0, 0, { preserveIndexes = true }) end
                chromeKey, changed = key, true
            end
        elseif chromeKey then
            chromeKey, rowCache = nil, {}
        end

        for row = useChrome and 3 or 1, scene and topRows or rows do
            local text, fg, bg = surface.getLine(row)
            local key = text .. fg .. bg
            local redrawCursor = cursor and cursor.y == row
            local newCursor = presentedCursor and presentedCursor.y == row
            if rowCache[row] ~= key or redrawCursor or newCursor then
                local y
                if row <= topRows then
                    local top = (row - 1) * chromeRowHeight
                    local base = tonumber(bg:sub(1, 1), 16)
                    screen.fillRect(0, top, width, chromeRowHeight, base)
                    y = top + math.floor((chromeRowHeight - fontSize) / 2)
                else
                    y = topPixels + (row - topRows - 1) * fontSize
                end
                drawRow(screen, 0, y, text, fg, bg, fontSize)
                if row > topRows and tab.showVerticalScrollbar and not (state.menuOpen or state.modal.open or tab.applet) then
                    local thumb = bg:sub(-1) == "8"
                    local barX = contentWidth - cellWidth
                    screen.fillRect(barX, y, cellWidth, fontSize, chrome.track)
                    if thumb then screen.fillRect(barX + 2, y, cellWidth - 4, fontSize, chrome.thumb) end
                end
                if newCursor then
                    screen.fillRect((presentedCursor.x - 1) * cellWidth, y + fontSize - 1, cellWidth, 1, chrome.accent)
                end
                rowCache[row], changed = key, true
            end
        end
        cursor = not scene and presentedCursor or nil
        if changed then screen.present() end
    end

    local function translate(event)
        local name = event[1]
        if not (screen and event[2] == target) then return nil end
        local mapped = pointerEvents[name]
        if not mapped and name ~= "display_touch" then return nil end
        local button, x, y = event[3], event[4], event[5]
        if name == "display_touch" then
            button, x, y = 1, event[3], event[4]
            mapped = "mouse_click"
        end
        local topRows = drawnTopRows or 2
        local topPixels = topRows * chromeRowHeight
        if scene == "home" and y >= topPixels and mapped == "mouse_click" then
            if button == 1 then
                for _, area in ipairs(startActions or {}) do
                    if x >= area.x and x < area.x + area.w and y >= area.y and y < area.y + area.h then
                        return { "browser_start_action", area.target }
                    end
                end
            end
            return nil
        end
        local captured = name == "display_drag" or name == "display_up"
        if not captured and (x >= contentWidth or y >= topPixels + (rows - topRows) * fontSize) then return nil end
        local row = y < topPixels and math.floor(y / chromeRowHeight) + 1
            or topRows + math.floor((y - topPixels) / fontSize) + 1
        return {
            mapped, button, math.min(columns, math.floor(x / cellWidth) + 1),
            math.min(rows, row), name == "display_touch" and "monitor_touch" or nil,
        }
    end

    return {
        open = open,
        close = close,
        draw = draw,
        translate = translate,
        resize = geometry,
        target = function() return target end,
        isOpen = function() return screen and screen.isOpen() end,
        supportsImages = function() return api and api.hasFeature and api.hasFeature("imageBytes") end,
        requestClipboard = function(operation, text)
            if target ~= "native" or not screen.requestHostClipboard then return nil end
            return screen.requestHostClipboard(operation, text)
        end,
    }
end
