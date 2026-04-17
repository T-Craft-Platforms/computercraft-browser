return function(deps)
    local state = deps.state
    local clamp = deps.clamp
    local TOP_BAR_ROWS = deps.topBarRows or 2
    local activeTab = deps.activeTab
    local canGoBack = deps.canGoBack
    local canGoForward = deps.canGoForward
    local tabTitle = deps.tabTitle
    local getUrlSelection = deps.getUrlSelection
    local normalizedPageSelection = deps.normalizedPageSelection
    local pageSelectionContains = deps.pageSelectionContains

    local function layoutUi()
        local w, _ = term.getSize()
        state.ui.closeBrowser = { x1 = 1, x2 = 1, y = 1 }
        state.ui.back = { x1 = 1, x2 = 3, y = 2 }
        state.ui.forward = { x1 = 5, x2 = 7, y = 2 }
        state.ui.reload = { x1 = 9, x2 = 11, y = 2 }
        state.ui.url = { x1 = 13, x2 = w, y = 2 }
        state.ui.newTab = { x1 = math.max(1, w - 2), x2 = w, y = 1 }
        state.ui.tabs = {}
        state.ui.tabClose = {}

        local tabsStart = state.ui.closeBrowser.x2 + 2
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
        local region = state.ui.tabs[index]
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

    local function revealTabName(index)
        local tabItem = state.tabs[index]
        if not tabItem then
            return
        end

        state.tabNameReveal = {
            index = index,
            text = tabTitle(tabItem),
        }
        if state.tabRevealTimer and os.cancelTimer then
            pcall(os.cancelTimer, state.tabRevealTimer)
        end
        state.tabRevealTimer = os.startTimer(2)
    end

    local function drawTopBar()
        layoutUi()
        local w, _ = term.getSize()
        local tab = activeTab()

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

            if #label > maxLabel then
                if maxLabel <= 1 then
                    label = label:sub(1, maxLabel)
                else
                    label = label:sub(1, maxLabel - 1) .. "~"
                end
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
        writeClipped(state.ui.newTab.x1, 1, string.rep(" ", newWidth), colors.black, colors.lightGray)
        local plusX = state.ui.newTab.x1 + math.floor((newWidth - 1) / 2)
        writeClipped(plusX, 1, "+", colors.black, colors.lightGray)

        local function drawButton(region, label, enabled, active)
            local bg = colors.gray
            local fg = colors.lightGray
            if enabled then
                bg = active and colors.orange or colors.lightGray
                fg = colors.black
            end
            local width = region.x2 - region.x1 + 1
            writeClipped(region.x1, region.y, string.rep(" ", width), fg, bg)
            local labelX = region.x1 + math.floor((width - #label) / 2)
            writeClipped(labelX, region.y, label, fg, bg)
        end

        drawButton(state.ui.back, "<", canGoBack(tab), false)
        drawButton(state.ui.forward, ">", canGoForward(tab), false)
        drawButton(state.ui.reload, tab.loading and "X" or "R", tab.loading or tab.document ~= nil, tab.loading)

        if state.ui.url.x1 <= state.ui.url.x2 then
            local urlFieldBg = colors.lightGray
            local urlFieldFg = colors.black
            local fieldWidth = state.ui.url.x2 - state.ui.url.x1 + 1
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

            local visible = tab.urlInput:sub(tab.urlOffset + 1, tab.urlOffset + fieldWidth)
            if #visible < fieldWidth then
                visible = visible .. string.rep(" ", fieldWidth - #visible)
            end

            writeClipped(state.ui.url.x1, 2, visible, urlFieldFg, urlFieldBg)

            local selStart, selEnd = getUrlSelection(tab)
            if selStart then
                local visibleStart = tab.urlOffset + 1
                local visibleEnd = tab.urlOffset + fieldWidth
                local drawStart = math.max(selStart, visibleStart)
                local drawEnd = math.min(selEnd - 1, visibleEnd)
                for charIndex = drawStart, drawEnd do
                    local relative = charIndex - visibleStart + 1
                    local cursorX = state.ui.url.x1 + relative - 1
                    local ch = visible:sub(relative, relative)
                    if ch == "" then
                        ch = " "
                    end
                    writeClipped(cursorX, 2, ch, colors.white, colors.blue)
                end
            end

            local reveal = state.tabNameReveal
            if reveal and reveal.index == state.activeTab and not tab.urlFocus then
                local revealText = reveal.text or tabTitle(tab)
                local revealPadded = " " .. revealText
                if #revealPadded < fieldWidth then
                    revealPadded = revealPadded .. string.rep(" ", fieldWidth - #revealPadded)
                end
                writeClipped(state.ui.url.x1, 2, revealPadded, colors.white, colors.blue)
            end

            local rightEdge = state.ui.url.x2
            if tab.loading then
                local loadingLabel = " loading "
                local startX = math.max(state.ui.url.x1, rightEdge - #loadingLabel + 1)
                writeClipped(startX, 2, loadingLabel, colors.yellow, colors.gray)
                rightEdge = startX - 1
            end

            if state.caretMode and rightEdge >= state.ui.url.x1 then
                local caretLabel = " F7 "
                local caretX = math.max(state.ui.url.x1, rightEdge - #caretLabel + 1)
                writeClipped(caretX, 2, caretLabel, colors.black, colors.lime)
            end

            local cursorVisible = false
            if tab.urlFocus then
                local offset = cursor - tab.urlOffset
                local cursorX = state.ui.url.x1 + offset - 1
                if cursorX >= state.ui.url.x1 and cursorX <= state.ui.url.x2 then
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

    local function drawPage()
        local w, h = term.getSize()
        local tab = activeTab()
        local firstLine = tab.scroll + 1
        local visibleHeight = math.max(1, h - TOP_BAR_ROWS)
        local selection = state.caretMode and normalizedPageSelection(tab) or nil

        for row = 1, visibleHeight do
            local lineIndex = firstLine + row - 1
            local line = tab.pageLines[lineIndex]
            local chars = {}
            local fgs = {}
            local bgs = {}
            for x = 1, w do
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
            term.setCursorPos(1, row + TOP_BAR_ROWS)
            term.blit(table.concat(chars), table.concat(fgs), table.concat(bgs))
        end
    end

    local function draw()
        drawTopBar()
        drawPage()
    end

    return {
        layoutUi = layoutUi,
        tabIndexAt = tabIndexAt,
        tabCloseIndexAt = tabCloseIndexAt,
        revealTabName = revealTabName,
        drawTopBar = drawTopBar,
        drawPage = drawPage,
        draw = draw,
    }
end
