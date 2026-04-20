return function(deps)
    local state = deps.state
    local clamp = deps.clamp
    local TOP_BAR_ROWS = deps.topBarRows or 2
    local effectiveTopBarRows = deps.effectiveTopBarRows or function() return TOP_BAR_ROWS end
    local activeTab = deps.activeTab
    local isFavoriteUrl = deps.isFavoriteUrl or function()
        return false
    end
    local canFavoriteUrl = deps.canFavoriteUrl or function()
        return false
    end
    local canGoBack = deps.canGoBack
    local canGoForward = deps.canGoForward
    local tabTitle = deps.tabTitle
    local getUrlSelection = deps.getUrlSelection
    local normalizedPageSelection = deps.normalizedPageSelection
    local pageSelectionContains = deps.pageSelectionContains

    local function layoutUi()
        local w, _ = term.getSize()

        -- In fullscreen mode, only the floating menu button is visible
        if state.fullscreen then
            local menuBtnWidth = 3
            -- Position off-screen elements consistently with x1 > x2 invalid but y = 0
            local offscreen = { x1 = 0, x2 = 0, y = 0 }
            state.ui.closeBrowser = offscreen
            state.ui.back = offscreen
            state.ui.forward = offscreen
            state.ui.reload = offscreen
            state.ui.newTab = offscreen
            state.ui.url = offscreen
            state.ui.tabs = {}
            state.ui.tabClose = {}
            -- Floating menu button at top-right corner
            state.ui.menuButton = { x1 = math.max(1, w - menuBtnWidth + 1), x2 = w, y = 1 }
            return
        end

        state.ui.closeBrowser = { x1 = 1, x2 = 1, y = 1 }
        state.ui.back = { x1 = 1, x2 = 3, y = 2 }
        state.ui.forward = { x1 = 5, x2 = 7, y = 2 }
        state.ui.reload = { x1 = 9, x2 = 11, y = 2 }
        state.ui.newTab = { x1 = math.max(1, w - 2), x2 = w, y = 1 }
        state.ui.menuButton = { x1 = state.ui.newTab.x1, x2 = state.ui.newTab.x2, y = 2 }
        state.ui.url = { x1 = 13, x2 = state.ui.menuButton.x1 - 1, y = 2 }
        state.ui.tabs = {}
        state.ui.tabClose = {}

        local tabsStart = state.ui.closeBrowser.x2 + 2
        local expandedIndex = state.expandedTabIndex
        if expandedIndex and (expandedIndex < 1 or expandedIndex > #state.tabs) then
            state.expandedTabIndex = nil
            expandedIndex = nil
        end

        if expandedIndex then
            state.ui.newTab = { x1 = w + 1, x2 = w, y = 1 }
            state.ui.menuButton = { x1 = state.ui.newTab.x1, x2 = state.ui.newTab.x2, y = 2 }
            state.ui.url = { x1 = 13, x2 = state.ui.menuButton.x1 - 1, y = 2 }
            local tabsEnd = w
            if tabsEnd >= tabsStart then
                state.ui.tabs[1] = { x1 = tabsStart, x2 = tabsEnd, y = 1, index = expandedIndex }
                if (tabsEnd - tabsStart + 1) >= 4 then
                    state.ui.tabClose[expandedIndex] = { x1 = tabsEnd, x2 = tabsEnd, y = 1, index = expandedIndex }
                end
            end
            return
        end

        local tabsEnd = state.ui.newTab.x1 - 1
        if tabsEnd < tabsStart or #state.tabs < 1 then
            return
        end

        local x = tabsStart
        local minWidth = 1
        local tabGap = 0
        local tabCount = #state.tabs
        local available = tabsEnd - tabsStart + 1
        local widths = {}
        local preferredWidths = {}
        local preferredTotal = 0

        for index = 1, tabCount do
            local preferred = #tabTitle(state.tabs[index]) + 3
            preferred = math.max(minWidth, preferred)
            preferredWidths[index] = preferred
            preferredTotal = preferredTotal + preferred
        end
        preferredTotal = preferredTotal + (tabCount - 1) * tabGap

        if preferredTotal > available then
            local contentSpace = math.max(tabCount * minWidth, available - ((tabCount - 1) * tabGap))
            local evenWidth = math.max(minWidth, math.floor(contentSpace / tabCount))
            local remainder = contentSpace - (evenWidth * tabCount)
            for index = 1, tabCount do
                widths[index] = evenWidth + ((index <= remainder) and 1 or 0)
            end
        else
            for index = 1, tabCount do
                widths[index] = preferredWidths[index]
            end
        end

        for index = 1, tabCount do
            if x > tabsEnd then
                break
            end
            local remaining = tabCount - index + 1
            local remainingSpace = tabsEnd - x + 1
            local minForRest = (remaining - 1) * (minWidth + tabGap)
            local maxForThis = math.max(minWidth, remainingSpace - minForRest)
            local width = clamp(widths[index] or minWidth, minWidth, maxForThis)
            local x2 = math.min(tabsEnd, x + width - 1)
            width = x2 - x + 1
            state.ui.tabs[index] = { x1 = x, x2 = x2, y = 1, index = index }
            if width >= 4 then
                state.ui.tabClose[index] = { x1 = x2, x2 = x2, y = 1, index = index }
            end
            x = x2 + 1 + tabGap
        end
    end

    local function writeClipped(x, y, text, textColor, backgroundColor)
        local w, _ = term.getSize()
        if x > w or y < 1 then
            return
        end
        local clipped = text
        local maxChars = w - x + 1
        if maxChars <= 0 then
            return
        end
        if #clipped > maxChars then
            clipped = clipped:sub(1, maxChars)
        end
        term.setCursorPos(x, y)
        if textColor then
            term.setTextColor(textColor)
        end
        if backgroundColor then
            term.setBackgroundColor(backgroundColor)
        end
        term.write(clipped)
    end

    local function tabIndexAt(x)
        for _, region in ipairs(state.ui.tabs) do
            if x >= region.x1 and x <= region.x2 then
                return region.index
            end
        end
        return nil
    end

    local function tabCloseIndexAt(x)
        for _, region in pairs(state.ui.tabClose) do
            if x >= region.x1 and x <= region.x2 then
                return region.index
            end
        end
        return nil
    end

    local function tabLabelLimit(index)
        local region = nil
        for _, tabRegion in ipairs(state.ui.tabs) do
            if tabRegion.index == index then
                region = tabRegion
                break
            end
        end
        if not region then
            return 0
        end

        local width = region.x2 - region.x1 + 1
        local closeRegion = state.ui.tabClose[index]
        if closeRegion then
            return math.max(0, width - 3)
        end
        return math.max(0, width - 1)
    end

    local function animatedExpandedLabel(index, label, maxLabel)
        if maxLabel <= 0 then
            return ""
        end
        if #label <= maxLabel then
            if state.tabTitleCarousel and state.tabTitleCarousel.index == index then
                state.tabTitleCarousel = nil
            end
            return label
        end

        local overflow = #label - maxLabel
        local now = os.clock()
        local carousel = state.tabTitleCarousel
        if (not carousel)
            or carousel.index ~= index
            or carousel.label ~= label
            or carousel.maxLabel ~= maxLabel then
            carousel = {
                index = index,
                label = label,
                maxLabel = maxLabel,
                offset = 0,
                dir = 1,
                lastTick = now,
                pauseUntil = now + 0.45,
            }
            state.tabTitleCarousel = carousel
        end

        local stepInterval = 0.18
        if now >= (carousel.pauseUntil or 0) then
            local elapsed = now - (carousel.lastTick or now)
            local steps = math.floor(elapsed / stepInterval)
            if steps > 0 then
                carousel.lastTick = (carousel.lastTick or now) + (steps * stepInterval)
                for _ = 1, steps do
                    local nextOffset = carousel.offset + carousel.dir
                    if nextOffset >= overflow then
                        carousel.offset = overflow
                        carousel.dir = -1
                        carousel.pauseUntil = now + 0.45
                        carousel.lastTick = now
                        break
                    elseif nextOffset <= 0 then
                        carousel.offset = 0
                        carousel.dir = 1
                        carousel.pauseUntil = now + 0.45
                        carousel.lastTick = now
                        break
                    else
                        carousel.offset = nextOffset
                    end
                end
            end
        else
            carousel.lastTick = now
        end

        local start = 1 + (carousel.offset or 0)
        return label:sub(start, start + maxLabel - 1)
    end

    local function drawTopBar()
        layoutUi()
        local w, _ = term.getSize()
        local tab = activeTab()

        -- In fullscreen mode, skip the full top bar. Only draw a floating "=" button.
        if state.fullscreen then
            state.tabTitleCarousel = nil
            -- Draw the floating "=" menu button
            local menuWidth = state.ui.menuButton.x2 - state.ui.menuButton.x1 + 1
            if menuWidth > 0 then
                local menuActive = state.menuOpen == true
                local menuBg = menuActive and colors.white or colors.gray
                local menuFg = menuActive and colors.black or colors.lightGray
                writeClipped(state.ui.menuButton.x1, 1, string.rep(" ", menuWidth), menuFg, menuBg)
                local menuX = state.ui.menuButton.x1 + math.floor((menuWidth - 1) / 2)
                writeClipped(menuX, 1, "=", menuFg, menuBg)
            end
            term.setCursorBlink(false)
            return
        end

        if not state.expandedTabIndex then
            state.tabTitleCarousel = nil
        end

        term.setBackgroundColor(colors.gray)
        term.setTextColor(colors.black)
        term.setCursorPos(1, 1)
        term.write(string.rep(" ", w))
        term.setCursorPos(1, 2)
        term.write(string.rep(" ", w))

        writeClipped(state.ui.closeBrowser.x1, state.ui.closeBrowser.y, "x", colors.lightGray, colors.gray)

        for _, region in ipairs(state.ui.tabs) do
            local tabItem = state.tabs[region.index]
            local isActive = region.index == state.activeTab
            local bg = isActive and colors.white or colors.lightGray
            local fg = isActive and colors.black or colors.gray
            local width = region.x2 - region.x1 + 1
            local label = tabTitle(tabItem)
            local closeRegion = state.ui.tabClose[region.index]
            local maxLabel = tabLabelLimit(region.index)
            local isExpanded = state.expandedTabIndex and region.index == state.expandedTabIndex

            if #label > maxLabel then
                if isExpanded then
                    label = animatedExpandedLabel(region.index, label, maxLabel)
                else
                    if maxLabel <= 1 then
                        label = label:sub(1, maxLabel)
                    else
                        label = label:sub(1, maxLabel - 1) .. "~"
                    end
                end
            elseif isExpanded then
                state.tabTitleCarousel = nil
            end

            if closeRegion then
                local bodyWidth = math.max(0, width - 2)
                local body = " " .. label
                if #body < bodyWidth then
                    body = body .. string.rep(" ", bodyWidth - #body)
                elseif #body > bodyWidth then
                    body = body:sub(1, bodyWidth)
                end
                writeClipped(region.x1, 1, body, fg, bg)
                writeClipped(region.x1 + bodyWidth, 1, " ", fg, bg)
                writeClipped(closeRegion.x1, 1, "x", fg, bg)
            else
                local body = " " .. label
                if #body < width then
                    body = body .. string.rep(" ", width - #body)
                elseif #body > width then
                    body = body:sub(1, width)
                end
                writeClipped(region.x1, 1, body, fg, bg)
            end
        end

        local newWidth = state.ui.newTab.x2 - state.ui.newTab.x1 + 1
        if newWidth > 0 then
            writeClipped(state.ui.newTab.x1, 1, string.rep(" ", newWidth), colors.lightGray, colors.gray)
            local plusX = state.ui.newTab.x1 + math.floor((newWidth - 1) / 2)
            writeClipped(plusX, 1, "+", colors.lightGray, colors.gray)
        end
        local menuWidth = state.ui.menuButton.x2 - state.ui.menuButton.x1 + 1
        if menuWidth > 0 then
            local menuActive = state.menuOpen == true
            local menuBg = menuActive and colors.white or colors.gray
            local menuFg = menuActive and colors.black or colors.lightGray
            writeClipped(state.ui.menuButton.x1, 2, string.rep(" ", menuWidth), menuFg, menuBg)
            local menuX = state.ui.menuButton.x1 + math.floor((menuWidth - 1) / 2)
            writeClipped(menuX, 2, "=", menuFg, menuBg)
        end

        local function drawButton(region, label, enabled, active)
            local bg = colors.gray
            local fg = colors.black
            if enabled then
                fg = colors.lightGray
                if active then
                    bg = colors.gray
                    fg = colors.yellow
                end
            end
            local width = region.x2 - region.x1 + 1
            writeClipped(region.x1, region.y, string.rep(" ", width), fg, bg)
            local labelX = region.x1 + math.floor((width - #label) / 2)
            writeClipped(labelX, region.y, label, fg, bg)
        end

        drawButton(state.ui.back, "<", canGoBack(tab), false)
        drawButton(state.ui.forward, ">", canGoForward(tab), false)
        drawButton(state.ui.reload, tab.loading and "x" or "r", tab.loading or tab.document ~= nil, tab.loading)

        if state.ui.url.x1 <= state.ui.url.x2 then
            local urlFieldBg = colors.lightGray
            local urlFieldFg = colors.black
            local fullUrlX1 = state.ui.url.x1
            local fullUrlX2 = state.ui.url.x2
            local caretLabel = state.caretMode and " F7 " or nil
            local inputX1 = fullUrlX1
            local inputX2 = fullUrlX2
            if caretLabel then
                local totalWidth = fullUrlX2 - fullUrlX1 + 1
                if totalWidth > #caretLabel then
                    inputX2 = fullUrlX2 - #caretLabel
                else
                    inputX2 = fullUrlX1
                end
            end
            if inputX2 < inputX1 then
                inputX2 = inputX1
            end
            local fieldWidth = inputX2 - inputX1 + 1
            local cursor = clamp(tab.urlCursor, 1, #tab.urlInput + 1)
            tab.urlCursor = cursor

            if cursor - tab.urlOffset > fieldWidth then
                tab.urlOffset = cursor - fieldWidth
            end
            if cursor <= tab.urlOffset then
                tab.urlOffset = cursor - 1
            end
            if tab.urlOffset < 0 then
                tab.urlOffset = 0
            end
            local maxOffset = math.max(0, (#tab.urlInput + 1) - fieldWidth)
            if tab.urlOffset > maxOffset then
                tab.urlOffset = maxOffset
            end

            local visible = tab.urlInput:sub(tab.urlOffset + 1, tab.urlOffset + fieldWidth)
            if #visible < fieldWidth then
                visible = visible .. string.rep(" ", fieldWidth - #visible)
            end

            writeClipped(inputX1, 2, visible, urlFieldFg, urlFieldBg)

            local selStart, selEnd = getUrlSelection(tab)
            if selStart then
                local visibleStart = tab.urlOffset + 1
                local visibleEnd = tab.urlOffset + fieldWidth
                local drawStart = math.max(selStart, visibleStart)
                local drawEnd = math.min(selEnd - 1, visibleEnd)
                for charIndex = drawStart, drawEnd do
                    local relative = charIndex - visibleStart + 1
                    local cursorX = inputX1 + relative - 1
                    local ch = visible:sub(relative, relative)
                    if ch == "" then
                        ch = " "
                    end
                    writeClipped(cursorX, 2, ch, colors.white, colors.blue)
                end
            end

            if caretLabel then
                local indicatorX1 = math.max(inputX2 + 1, fullUrlX1)
                if indicatorX1 <= fullUrlX2 then
                    writeClipped(
                        indicatorX1,
                        2,
                        string.rep(" ", fullUrlX2 - indicatorX1 + 1),
                        colors.black,
                        colors.lime
                    )
                    local labelX = math.max(indicatorX1, fullUrlX2 - #caretLabel + 1)
                    writeClipped(labelX, 2, caretLabel, colors.black, colors.lime)
                end
            end

            local cursorVisible = false
            if tab.urlFocus then
                local offset = cursor - tab.urlOffset
                local cursorX = inputX1 + offset - 1
                if cursorX >= inputX1 and cursorX <= inputX2 then
                    local cursorChar = visible:sub(offset, offset)
                    if cursorChar == "" then
                        cursorChar = " "
                    end
                    writeClipped(cursorX, 2, cursorChar, colors.black, colors.white)
                    term.setCursorPos(cursorX, 2)
                    cursorVisible = true
                end
            end
            term.setCursorBlink(cursorVisible)
        else
            term.setCursorBlink(false)
        end
    end

    local function verticalScrollbarGeometry(tab, visibleHeight)
        if not tab.showVerticalScrollbar then
            return nil
        end

        local contentHeight = math.max(1, tonumber(tab.pageContentHeight) or #tab.pageLines)
        local maxScroll = math.max(0, contentHeight - visibleHeight)
        local thumbHeight = visibleHeight
        if contentHeight > visibleHeight then
            thumbHeight = math.floor((visibleHeight * visibleHeight) / contentHeight + 0.5)
            thumbHeight = clamp(thumbHeight, 1, visibleHeight)
        end

        local travel = visibleHeight - thumbHeight
        local thumbTop = 1
        if maxScroll > 0 and travel > 0 then
            local ratio = tab.scroll / maxScroll
            thumbTop = 1 + math.floor((ratio * travel) + 0.5)
        end

        return {
            thumbTop = thumbTop,
            thumbHeight = thumbHeight,
        }
    end

    local function drawPage()
        local w, h = term.getSize()
        local tab = activeTab()
        local firstLine = tab.scroll + 1
        local topRows = effectiveTopBarRows()
        local visibleHeight = math.max(1, h - topRows)
        local selection = state.caretMode and normalizedPageSelection(tab) or nil
        local viewportWidth = clamp(tab.viewportWidth or w, 1, w)
        local scrollbar = verticalScrollbarGeometry(tab, visibleHeight)

        for row = 1, visibleHeight do
            local lineIndex = firstLine + row - 1
            local line = tab.pageLines[lineIndex]
            local chars = {}
            local fgs = {}
            local bgs = {}
            for x = 1, viewportWidth do
                local ch = " "
                local fg = colors.white
                local bg = colors.black
                if line then
                    ch = line.chars[x] or " "
                    fg = line.fg[x] or colors.white
                    bg = line.bg[x] or colors.black
                end
                if selection and pageSelectionContains(selection, lineIndex, x) then
                    fg = colors.white
                    bg = colors.blue
                end
                chars[x] = ch
                fgs[x] = colors.toBlit(fg)
                bgs[x] = colors.toBlit(bg)
            end
            for x = viewportWidth + 1, w do
                chars[x] = " "
                fgs[x] = colors.toBlit(colors.white)
                bgs[x] = colors.toBlit(colors.black)
            end
            if scrollbar and w >= 1 then
                local inThumb = row >= scrollbar.thumbTop and row < (scrollbar.thumbTop + scrollbar.thumbHeight)
                chars[w] = " "
                fgs[w] = colors.toBlit(colors.white)
                bgs[w] = colors.toBlit(inThumb and colors.lightGray or colors.gray)
            end
            term.setCursorPos(1, row + topRows)
            term.blit(table.concat(chars), table.concat(fgs), table.concat(bgs))
        end

        local currentUrl = tostring(tab.currentUrl or ""):lower()
        local statusText = tostring(tab.settingsStickyStatus or "")
        if statusText ~= "" and currentUrl:sub(1, #"about:settings") == "about:settings" then
            local badge = " " .. statusText .. " "
            local maxBadgeWidth = math.max(12, math.floor(w * 0.55))
            if #badge > maxBadgeWidth then
                local inner = math.max(1, maxBadgeWidth - 5)
                badge = " " .. statusText:sub(1, inner) .. "... "
            end
            local x = math.max(1, w - #badge + 1)
            writeClipped(x, topRows + 1, badge, colors.black, colors.lime)
        end
    end

    local function drawMenuPopover()
        state.ui.menu = nil
        if not state.menuOpen then
            return
        end

        local w, h = term.getSize()
        if state.ui.menuButton.x1 > w then
            state.menuOpen = false
            return
        end
        local topRows = effectiveTopBarRows()
        local panelWidth = math.min(24, math.max(14, w))
        local panelHeight = 7
        local panelX2 = clamp(state.ui.menuButton.x2, 1, w)
        local panelX1 = math.max(1, panelX2 - panelWidth + 1)
        local panelY1 = topRows + 1
        if state.fullscreen then
            panelY1 = state.ui.menuButton.y + 1
        end
        local panelY2 = math.min(h, panelY1 + panelHeight - 1)

        state.ui.menu = {
            panel = { x1 = panelX1, x2 = panelX2, y1 = panelY1, y2 = panelY2 },
        }

        for y = panelY1, panelY2 do
            writeClipped(panelX1, y, string.rep(" ", panelX2 - panelX1 + 1), colors.black, colors.lightGray)
        end

        local innerX1 = math.min(panelX2, panelX1 + 1)
        local textFg = colors.black
        local textBg = colors.lightGray

        local settingsY = panelY1
        local helpY = math.min(panelY2, panelY1 + 1)
        local favoritesY = math.min(panelY2, panelY1 + 2)
        local historyY = math.min(panelY2, panelY1 + 3)
        local printY = math.min(panelY2, panelY1 + 4)
        local fullscreenY = math.min(panelY2, panelY1 + 5)
        local exitY = math.min(panelY2, panelY1 + 6)

        writeClipped(innerX1, settingsY, "Settings", textFg, textBg)
        writeClipped(innerX1, helpY, "Help", textFg, textBg)
        local currentTab = activeTab()
        local currentUrl = tostring(currentTab.currentUrl or "")
        local addFavoriteEnabled = canFavoriteUrl(currentUrl)
        local favoriteActive = addFavoriteEnabled and isFavoriteUrl(currentUrl)
        local favTextX1 = panelX1
        local favTextX2 = panelX2
        local heartX1 = nil
        local heartX2 = nil

        if addFavoriteEnabled then
            local heartLabel = "<3"
            heartX2 = panelX2
            heartX1 = math.max(panelX1, heartX2 - #heartLabel + 1)
            favTextX2 = math.max(panelX1, heartX1 - 1)
            local heartFg = favoriteActive and colors.red or colors.gray
            writeClipped(heartX1, favoritesY, heartLabel, heartFg, textBg)
        end

        writeClipped(favTextX1, favoritesY, string.rep(" ", favTextX2 - favTextX1 + 1), textFg, textBg)
        writeClipped(favTextX1 + 1, favoritesY, "Favorites", textFg, textBg)
        writeClipped(innerX1, historyY, "History", textFg, textBg)
        writeClipped(innerX1, printY, "Print", textFg, textBg)
        local fullscreenLabel = state.fullscreen and "Exit Fullscreen" or "Fullscreen"
        writeClipped(innerX1, fullscreenY, fullscreenLabel, textFg, textBg)
        writeClipped(innerX1, exitY, "Exit", textFg, textBg)

        state.ui.menu.settings = { x1 = panelX1, x2 = panelX2, y = settingsY }
        state.ui.menu.help = { x1 = panelX1, x2 = panelX2, y = helpY }
        if addFavoriteEnabled and heartX1 and heartX2 then
            state.ui.menu.addFavorite = { x1 = heartX1, x2 = heartX2, y = favoritesY }
        else
            state.ui.menu.addFavorite = nil
        end
        state.ui.menu.addFavoriteEnabled = addFavoriteEnabled
        state.ui.menu.favorites = { x1 = panelX1, x2 = favTextX2, y = favoritesY }
        state.ui.menu.history = { x1 = panelX1, x2 = panelX2, y = historyY }
        state.ui.menu.print = { x1 = panelX1, x2 = panelX2, y = printY }
        state.ui.menu.fullscreen = { x1 = panelX1, x2 = panelX2, y = fullscreenY }
        state.ui.menu.exit = { x1 = panelX1, x2 = panelX2, y = exitY }
    end

    local function draw()
        drawTopBar()
        drawPage()
        drawMenuPopover()
    end

    return {
        layoutUi = layoutUi,
        tabIndexAt = tabIndexAt,
        tabCloseIndexAt = tabCloseIndexAt,
        drawTopBar = drawTopBar,
        drawPage = drawPage,
        draw = draw,
    }
end
