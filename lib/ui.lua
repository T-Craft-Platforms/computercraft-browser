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
    local oskEnabled = deps.oskEnabled or function() return false end
    local getOskState = deps.getOskState or function()
        return {
            open = false,
            page = 1,
            shift = false,
            caps = false,
            ctrl = false,
            accentMenu = false,
            pendingAccent = nil,
            pressedKey = nil,
            pressedUntil = 0,
        }
    end
    local getOskLayout = deps.getOskLayout or function()
        return "qwerty"
    end

    local OSK_ROWS = 4

    -- Compute proportional key positions for a single OSK row.
    local function computeKeyRow(totalWidth, y, keyDefs)
        local totalWeight = 0
        for _, k in ipairs(keyDefs) do
            totalWeight = totalWeight + (k.weight or 1)
        end
        if totalWeight <= 0 then totalWeight = 1 end
        local result = {}
        local x = 1
        for i, k in ipairs(keyDefs) do
            local kw
            if i == #keyDefs then
                kw = math.max(1, totalWidth - x + 1)
            else
                local keysLeft = #keyDefs - i
                local remaining = totalWidth - x + 1
                kw = math.max(1, math.min(
                    math.floor(totalWidth * (k.weight or 1) / totalWeight + 0.5),
                    remaining - keysLeft
                ))
            end
            result[i] = {
                x1 = x, x2 = x + kw - 1, y = y,
                label = k.label, action = k.action or "none", value = k.value,
            }
            x = x + kw
        end
        return result
    end

    local function oskLetterRows(layoutName)
        local rows = {
            row1 = {"q", "w", "e", "r", "t", "y", "u", "i", "o", "p"},
            row2 = {"a", "s", "d", "f", "g", "h", "j", "k", "l"},
            row3 = {"z", "x", "c", "v", "b", "n", "m"},
        }
        if layoutName == "qwertz" then
            rows.row1 = {"q", "w", "e", "r", "t", "z", "u", "i", "o", "p"}
            rows.row2 = {"a", "s", "d", "f", "g", "h", "j", "k", "l"}
            rows.row3 = {"y", "x", "c", "v", "b", "n", "m"}
        elseif layoutName == "azerty" then
            rows.row1 = {"a", "z", "e", "r", "t", "y", "u", "i", "o", "p"}
            rows.row2 = {"q", "s", "d", "f", "g", "h", "j", "k", "l", "m"}
            rows.row3 = {"w", "x", "c", "v", "b", "n"}
        end
        return rows
    end

    local function resolveLetterValue(letter, shift, caps)
        local upper = (caps and not shift) or (shift and not caps)
        return upper and letter:upper() or letter
    end

    local function resolveSymbolValue(baseValue, shiftedValue, shift, caps)
        if shiftedValue and (shift or caps) then
            return shiftedValue
        end
        return baseValue
    end

    local function makeLetterKeys(chars, shift, caps)
        local out = {}
        for _, c in ipairs(chars) do
            local rendered = resolveLetterValue(c, shift, caps)
            out[#out + 1] = {
                label = rendered,
                action = "char",
                value = rendered,
                weight = 1,
            }
        end
        return out
    end

    local function makeSymbolKey(label, value, shiftedValue, shift, caps, weight)
        local rendered = resolveSymbolValue(value, shiftedValue, shift, caps)
        return {
            label = label or rendered,
            action = "char",
            value = rendered,
            weight = weight or 1,
        }
    end

    -- Build all 4 OSK rows for the given page/modifier state.
    local function buildOskRows(w, h, osk)
        local page = osk.page or 1
        local shift = osk.shift or false
        local caps = osk.caps or false
        local ctrl = osk.ctrl or false
        local y1 = h - OSK_ROWS + 1
        local rows = {}
        local layout = oskLetterRows(tostring(getOskLayout() or "qwerty"):lower())

        if page == 1 then
            rows[1] = computeKeyRow(w, y1, makeLetterKeys(layout.row1, shift, caps))

            local row2 = makeLetterKeys(layout.row2, shift, caps)
            row2[#row2 + 1] = makeSymbolKey(nil, ".", ":", shift, caps)
            rows[2] = computeKeyRow(w, y1 + 1, row2)

            local row3 = {
                {label = "^", action = "shift", weight = 1.8},
            }
            local letters = makeLetterKeys(layout.row3, shift, caps)
            for _, key in ipairs(letters) do
                row3[#row3 + 1] = key
            end
            row3[#row3 + 1] = makeSymbolKey(nil, "/", "?", shift, caps, 1)
            row3[#row3 + 1] = makeSymbolKey(nil, "-", "_", shift, caps, 1)
            row3[#row3 + 1] = {label = "<--", action = "backspace", weight = 2.0}
            rows[3] = computeKeyRow(w, y1 + 2, row3)

            rows[4] = computeKeyRow(w, y1 + 3, {
                {label = "CTRL", action = "ctrl", weight = 2.2},
                {label = "123", action = "page2", weight = 1.8},
                {label = "TAB", action = "tab", weight = 1.8},
                {label = "SPACE", action = "space", weight = 7.2},
                {label = "ENT", action = "enter", weight = 2.2},
            })
        elseif page == 2 then
            rows[1] = computeKeyRow(w, y1, {
                makeSymbolKey(nil, "1", nil, false, false),
                makeSymbolKey(nil, "2", nil, false, false),
                makeSymbolKey(nil, "3", nil, false, false),
                makeSymbolKey(nil, "4", nil, false, false),
                makeSymbolKey(nil, "5", nil, false, false),
                makeSymbolKey(nil, "6", nil, false, false),
                makeSymbolKey(nil, "7", nil, false, false),
                makeSymbolKey(nil, "8", nil, false, false),
                makeSymbolKey(nil, "9", nil, false, false),
                makeSymbolKey(nil, "0", nil, false, false),
            })

            rows[2] = computeKeyRow(w, y1 + 1, {
                makeSymbolKey(nil, ".", ":", false, false),
                makeSymbolKey(nil, "-", "_", false, false),
                makeSymbolKey(nil, "/", "?", false, false),
                makeSymbolKey(nil, ";", ":", false, false),
                makeSymbolKey(nil, "'", "\"", false, false),
                makeSymbolKey(nil, "(", ")", false, false),
                makeSymbolKey(nil, "[", "]", false, false),
                makeSymbolKey(nil, "=", "+", false, false),
            })

            rows[3] = computeKeyRow(w, y1 + 2, {
                makeSymbolKey(nil, ",", "<", false, false),
                makeSymbolKey(nil, "!", "!", false, false),
                makeSymbolKey(nil, "?", "?", false, false),
                makeSymbolKey(nil, "_", "_", false, false),
                makeSymbolKey(nil, ":", ":", false, false),
                {label = "<--", action = "backspace", weight = 2.2},
            })

            rows[4] = computeKeyRow(w, y1 + 3, {
                {label = "CTRL", action = "ctrl", weight = 2.2},
                {label = "abc", action = "page1", weight = 2.0},
                {label = "...", action = "page3", weight = 2.0},
                {label = "SPACE", action = "space", weight = 7.2},
                {label = "ENT", action = "enter", weight = 2.2},
            })
        else
            rows[1] = computeKeyRow(w, y1, {
                makeSymbolKey(nil, "@", "@", false, false),
                makeSymbolKey(nil, "#", "#", false, false),
                makeSymbolKey(nil, "$", "$", false, false),
                makeSymbolKey(nil, "%", "%", false, false),
                makeSymbolKey(nil, "&", "&", false, false),
                makeSymbolKey(nil, "*", "*", false, false),
                makeSymbolKey(nil, "`", "`", false, false),
                makeSymbolKey(nil, "~", "~", false, false),
                makeSymbolKey(nil, "^", "^", false, false),
            })

            rows[2] = computeKeyRow(w, y1 + 1, {
                makeSymbolKey(nil, "{", "{", false, false),
                makeSymbolKey(nil, "}", "}", false, false),
                makeSymbolKey(nil, "<", "<", false, false),
                makeSymbolKey(nil, ">", ">", false, false),
                makeSymbolKey(nil, "\\", "\\", false, false),
                makeSymbolKey(nil, "|", "|", false, false),
                makeSymbolKey(nil, "\"", "\"", false, false),
                makeSymbolKey(nil, "+", "+", false, false),
            })

            rows[3] = computeKeyRow(w, y1 + 2, {
                makeSymbolKey(nil, ")", ")", false, false),
                makeSymbolKey(nil, "]", "]", false, false),
                makeSymbolKey(nil, "{", "{", false, false),
                makeSymbolKey(nil, "}", "}", false, false),
                makeSymbolKey(nil, "|", "|", false, false),
                {label = "<--", action = "backspace", weight = 2.2},
            })

            rows[4] = computeKeyRow(w, y1 + 3, {
                {label = "CTRL", action = "ctrl", weight = 2.2},
                {label = "abc", action = "page1", weight = 2.0},
                {label = "123", action = "page2", weight = 2.0},
                {label = "SPACE", action = "space", weight = 7.2},
                {label = "ENT", action = "enter", weight = 2.2},
            })
        end

        return rows
    end

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
            state.ui.oskButton = nil
            if state.seamlessAppletFullscreen then
                state.ui.menuButton = offscreen
            else
                -- Floating menu button at top-right corner
                state.ui.menuButton = { x1 = math.max(1, w - menuBtnWidth + 1), x2 = w, y = 1 }
            end
            return
        end

        state.ui.closeBrowser = { x1 = 1, x2 = 1, y = 1 }
        state.ui.back = { x1 = 1, x2 = 3, y = 2 }
        state.ui.forward = { x1 = 5, x2 = 7, y = 2 }
        state.ui.reload = { x1 = 9, x2 = 11, y = 2 }
        state.ui.newTab = { x1 = math.max(1, w - 2), x2 = w, y = 1 }
        state.ui.menuButton = { x1 = state.ui.newTab.x1, x2 = state.ui.newTab.x2, y = 2 }
        -- OSK button sits immediately left of the menu button when OSK is enabled
        local urlEndX
        if oskEnabled() then
            local oskBtnX2 = state.ui.menuButton.x1 - 1
            local oskBtnX1 = oskBtnX2 - 2
            if oskBtnX1 >= 14 then
                state.ui.oskButton = { x1 = oskBtnX1, x2 = oskBtnX2, y = 2 }
                urlEndX = oskBtnX1 - 2
            else
                state.ui.oskButton = nil
                urlEndX = state.ui.menuButton.x1 - 1
            end
        else
            state.ui.oskButton = nil
            urlEndX = state.ui.menuButton.x1 - 1
        end
        state.ui.url = { x1 = 13, x2 = urlEndX, y = 2 }
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
            state.ui.oskButton = nil
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
                startedAt = now,
                pauseSeconds = 0.35,
                stepInterval = 0.12,
            }
            state.tabTitleCarousel = carousel
        end

        if overflow <= 0 then
            return label
        end

        local elapsed = math.max(0, now - (carousel.startedAt or now))
        local pause = tonumber(carousel.pauseSeconds) or 0
        local stepInterval = tonumber(carousel.stepInterval) or 0.12
        local offset = 0
        if elapsed > pause then
            local steps = math.floor((elapsed - pause) / stepInterval)
            local cycle = overflow * 2
            if cycle > 0 then
                local position = steps % cycle
                if position <= overflow then
                    offset = position
                else
                    offset = cycle - position
                end
            end
        end

        local start = 1 + offset
        return label:sub(start, start + maxLabel - 1)
    end

    local function drawTopBar()
        layoutUi()
        local w, _ = term.getSize()
        local tab = activeTab()
        local urlCursorState = { visible = false, x = 1, y = 2 }

        -- In fullscreen mode, skip the full top bar. Only draw a floating "=" button.
        if state.fullscreen then
            state.tabTitleCarousel = nil
            if state.seamlessAppletFullscreen then
                state.ui.urlCursor = { visible = false, x = 1, y = 1 }
                term.setCursorBlink(false)
                return
            end
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
            state.ui.urlCursor = { visible = false, x = 1, y = 1 }
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

        -- OSK toggle button ("K"), always visible left of "=" when OSK setting is enabled
        local oskBtn = state.ui.oskButton
        if oskBtn and oskBtn.x1 <= oskBtn.x2 then
            local osk = getOskState()
            local isOpen = osk and osk.open
            local btnBg = isOpen and colors.white or colors.gray
            local btnFg = isOpen and colors.black or colors.lightGray
            local btnW = oskBtn.x2 - oskBtn.x1 + 1
            writeClipped(oskBtn.x1, 2, string.rep(" ", btnW), btnFg, btnBg)
            local labelX = oskBtn.x1 + math.floor((btnW - 1) / 2)
            writeClipped(labelX, 2, "K", btnFg, btnBg)
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

            if tab.urlFocus then
                local offset = cursor - tab.urlOffset
                local cursorX = inputX1 + offset - 1
                if cursorX >= inputX1 and cursorX <= inputX2 then
                    local relative = cursorX - inputX1 + 1
                    local caretChar = visible:sub(relative, relative)
                    if caretChar == "" then
                        caretChar = " "
                    end
                    writeClipped(cursorX, 2, caretChar, urlFieldFg, colors.white)
                end
            end
            urlCursorState.visible = false
        else
            urlCursorState.visible = false
        end
        state.ui.urlCursor = urlCursorState
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
        local defaultBg = tab.pageDefaultBackground or colors.black
        local defaultFg = tab.pageDefaultForeground or colors.white
        local scrollbar = verticalScrollbarGeometry(tab, visibleHeight)

        for row = 1, visibleHeight do
            local lineIndex = firstLine + row - 1
            local line = tab.pageLines[lineIndex]
            local chars = {}
            local fgs = {}
            local bgs = {}
            for x = 1, viewportWidth do
                local ch = " "
                local fg = defaultFg
                local bg = defaultBg
                if line then
                    ch = line.chars[x] or " "
                    fg = line.fg[x] or defaultFg
                    bg = line.bg[x] or defaultBg
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
                fgs[x] = colors.toBlit(defaultFg)
                bgs[x] = colors.toBlit(defaultBg)
            end
            if scrollbar and w >= 1 then
                local inThumb = row >= scrollbar.thumbTop and row < (scrollbar.thumbTop + scrollbar.thumbHeight)
                chars[w] = " "
                fgs[w] = colors.toBlit(defaultFg)
                bgs[w] = colors.toBlit(inThumb and colors.lightGray or colors.gray)
            end
            term.setCursorPos(1, row + topRows)
            term.blit(table.concat(chars), table.concat(fgs), table.concat(bgs))
        end

        local currentUrl = tostring(tab.currentUrl or ""):lower()
        local statusText = tostring(tab.settingsStickyStatus or "")
        if statusText ~= "" and currentUrl:sub(1, #"about:settings") == "about:settings" then
            local statusRight = clamp(viewportWidth, 1, w)
            local badge = " " .. statusText .. " "
            local maxBadgeWidth = math.max(12, math.floor(statusRight * 0.55))
            if #badge > maxBadgeWidth then
                local inner = math.max(1, maxBadgeWidth - 5)
                badge = " " .. statusText:sub(1, inner) .. "... "
            end
            if #badge > statusRight then
                badge = badge:sub(1, statusRight)
            end
            local x = math.max(1, statusRight - #badge + 1)
            writeClipped(x, topRows + 1, badge, colors.black, colors.lime)
        end
    end

    local function drawMenuPopover()
        state.ui.menu = nil
        if state.seamlessAppletFullscreen then
            state.menuOpen = false
            return
        end
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
        local panelHeight = 8
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
        local downloadY = math.min(panelY2, panelY1 + 4)
        local printY = math.min(panelY2, panelY1 + 5)
        local fullscreenY = math.min(panelY2, panelY1 + 6)
        local exitY = math.min(panelY2, panelY1 + 7)

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
        writeClipped(innerX1, downloadY, "Download", textFg, textBg)
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
        state.ui.menu.download = { x1 = panelX1, x2 = panelX2, y = downloadY }
        state.ui.menu.print = { x1 = panelX1, x2 = panelX2, y = printY }
        state.ui.menu.fullscreen = { x1 = panelX1, x2 = panelX2, y = fullscreenY }
        state.ui.menu.exit = { x1 = panelX1, x2 = panelX2, y = exitY }
    end

    local function draw()
        drawTopBar()
        drawPage()
        drawMenuPopover()
        local urlCursor = state.ui and state.ui.urlCursor or nil
        if urlCursor and urlCursor.visible then
            term.setCursorPos(urlCursor.x or 1, urlCursor.y or 1)
        end
        term.setCursorBlink(false)
    end

    -- Draw the on-screen keyboard panel at the bottom of the screen.
    local function drawOsk()
        if not oskEnabled() then
            state.ui.oskLayout = nil
            return
        end
        local osk = getOskState()
        if not osk or not osk.open then
            state.ui.oskLayout = nil
            return
        end

        local w, h = term.getSize()
        local y1 = h - OSK_ROWS + 1

        -- Fill OSK background (gap color between keys)
        for y = y1, h do
            term.setCursorPos(1, y)
            term.setBackgroundColor(colors.gray)
            term.setTextColor(colors.lightGray)
            term.write(string.rep(" ", w))
        end

        local oskRows = buildOskRows(w, h, osk)
        local flash = osk.pressedKey
        local flashActive = flash
            and tonumber(osk.pressedUntil) ~= nil
            and os.clock() <= tonumber(osk.pressedUntil)

        for _, row in ipairs(oskRows) do
            for _, key in ipairs(row) do
                local kw = key.x2 - key.x1 + 1
                if kw >= 1 then
                    local isActive = (key.action == "shift" and (osk.shift or false))
                        or (key.action == "shift" and (osk.caps or false))
                        or (key.action == "ctrl" and (osk.ctrl or false))
                    local bg = isActive and colors.blue or colors.lightGray
                    local fg = isActive and colors.white or colors.black
                    if flashActive
                        and flash.action == "char"
                        and key.action == "char"
                        and flash.y == key.y
                        and flash.x1 == key.x1
                        and flash.x2 == key.x2 then
                        bg = colors.white
                        fg = colors.black
                    end

                    -- Inner key surface (1 px gap on each side when possible)
                    local innerX1 = key.x1 + 1
                    local innerX2 = key.x2 - 1
                    if innerX1 > innerX2 then
                        innerX1 = key.x1
                        innerX2 = key.x2
                    end
                    local innerW = innerX2 - innerX1 + 1

                    term.setCursorPos(innerX1, key.y)
                    term.setBackgroundColor(bg)
                    term.setTextColor(fg)
                    term.write(string.rep(" ", innerW))

                    local lbl = tostring(key.label or "")
                    if #lbl > innerW then lbl = lbl:sub(1, innerW) end
                    if #lbl > 0 then
                        local labelX = innerX1 + math.floor((innerW - #lbl) / 2)
                        term.setCursorPos(labelX, key.y)
                        term.write(lbl)
                    end
                end
            end
        end

        -- Store layout for click handling
        state.ui.oskLayout = oskRows
    end

    return {
        layoutUi = layoutUi,
        tabIndexAt = tabIndexAt,
        tabCloseIndexAt = tabCloseIndexAt,
        drawTopBar = drawTopBar,
        drawPage = drawPage,
        draw = draw,
        drawOsk = drawOsk,
    }
end
