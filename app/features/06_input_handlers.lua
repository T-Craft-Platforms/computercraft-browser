function handleTabClick(button, x)
    if hitRegion(x, 1, state.ui.closeBrowser) then
        state.running = false
        return
    end

    if hitRegion(x, 1, state.ui.newTab) then
        local newTabUrl = homePageUrl()
        local tab = newTab(newTabUrl)
        navigate(newTabUrl, true, false, tab)
        tab.urlFocus = true
        tab.urlCursor = #tab.urlInput + 1
        clearUrlSelection(tab)
        return
    end

    if button == 1 then
        local closeIndex = tabCloseIndexAt(x)
        if closeIndex then
            closeTab(closeIndex)
            return
        end
    end

    local index = tabIndexAt(x)
    if not index then
        local tab = activeTab()
        tab.urlFocus = false
        clearUrlSelection(tab)
        tab.focusedFormControl = nil
        return
    end

    local now = os.clock()
    local wasDoubleClick = button == 1
        and state.lastTabClick.button == button
        and state.lastTabClick.index == index
        and (now - (state.lastTabClick.at or 0)) <= 0.35

    if button == 1 and state.expandedTabIndex == index then
        collapseExpandedTab()
        state.tabDrag = nil
        state.scrollbarDrag = nil
        activateTab(index)
        clearUrlSelection(activeTab())
        state.lastTabClick = {
            index = nil,
            button = nil,
            at = 0,
        }
        return
    end

    activateTab(index)
    clearUrlSelection(activeTab())

    if wasDoubleClick then
        toggleExpandedTab(index)
        state.tabDrag = nil
        state.scrollbarDrag = nil
        state.lastTabClick = {
            index = nil,
            button = nil,
            at = 0,
        }
        return
    end

    state.lastTabClick = {
        index = index,
        button = button,
        at = now,
    }

    if button == 1 and not state.expandedTabIndex then
        state.tabDrag = { button = button, index = index }
    end
end

function handleToolbarClick(x)
    local tab = activeTab()
    if hitRegion(x, 2, state.ui.menuButton) then
        state.menuOpen = not state.menuOpen
        if state.menuOpen then
            tab.urlFocus = false
            clearUrlSelection(tab)
            tab.focusedFormControl = nil
        end
        state.tabDrag = nil
        state.scrollbarDrag = nil
        return
    end

    state.menuOpen = false

    if hitRegion(x, 2, state.ui.back) then
        tab.focusedFormControl = nil
        goBack()
        return
    end
    if hitRegion(x, 2, state.ui.forward) then
        tab.focusedFormControl = nil
        goForward()
        return
    end
    if hitRegion(x, 2, state.ui.reload) then
        tab.focusedFormControl = nil
        reloadPage()
        return
    end
    if hitRegion(x, 2, state.ui.url) then
        tab.urlFocus = true
        tab.focusedFormControl = nil
        local pos = tab.urlOffset + (x - state.ui.url.x1) + 1
        tab.urlCursor = clamp(pos, 1, #tab.urlInput + 1)
        clearUrlSelection(tab)
        return
    end
    tab.urlFocus = false
    clearUrlSelection(tab)
    tab.focusedFormControl = nil
end

function handleFullscreenMenuButtonClick(x, y)
    if not state.fullscreen then
        return false
    end
    if seamlessAppletFullscreenActive and seamlessAppletFullscreenActive() then
        return false
    end
    if not hitRegion(x, y, state.ui.menuButton) then
        return false
    end

    state.menuOpen = not state.menuOpen
    if state.menuOpen then
        local tab = activeTab()
        tab.urlFocus = false
        clearUrlSelection(tab)
        tab.focusedFormControl = nil
    end
    state.tabDrag = nil
    state.scrollbarDrag = nil
    return true
end

function handleScrollbarClick(button, x, y, tab, topRows)
    local scrollbar = verticalScrollbarMetrics(tab)
    if not scrollbar or x ~= scrollbar.x then
        return false
    end
    if button ~= 1 then
        return true
    end
    if scrollbar.maxScroll <= 0 then
        return true
    end

    local clickRow = clamp(y - topRows, 1, scrollbar.viewportHeight)
    local thumbBottom = scrollbar.thumbTop + scrollbar.thumbHeight - 1
    if clickRow >= scrollbar.thumbTop and clickRow <= thumbBottom then
        state.scrollbarDrag = {
            button = button,
            tab = tab,
            grabOffset = clickRow - scrollbar.thumbTop,
        }
    elseif clickRow < scrollbar.thumbTop then
        setScroll(tab.scroll - scrollbar.viewportHeight, tab)
    else
        setScroll(tab.scroll + scrollbar.viewportHeight, tab)
    end
    return true
end

function handlePageContentClick(button, x, y, tab, topRows)
    local viewportWidth = pageContentWidth(tab)
    local lineIndex = clamp(tab.scroll + (y - topRows), 1, pageLineCount(tab))
    local column = clamp(x, 1, viewportWidth)

    if state.caretMode then
        if button == 1 then
            setPageSelection(tab, lineIndex, column, lineIndex, column)
        end
        return true
    end

    clearPageSelection(tab)
    local line = tab.pageLines[lineIndex]
    local controlKey = line and line.controls and line.controls[column] or nil
    if controlKey then
        state.menuOpen = false
        activateFormControl(tab, controlKey)
        return true
    end

    tab.focusedFormControl = nil
    local href = line and line.links and line.links[column] or nil
    if href then
        local action = select(1, parseAppletActionUrl(href))
        if action ~= nil and tab.pendingApplet then
            state.menuOpen = false
            return handleAppletActionNavigation(href, tab)
        end
        state.menuOpen = false
        navigate(href, true, false, tab)
        return true
    end
    return false
end

function handleMouseClick(button, x, y)
    layoutUi()
    local topRows = effectiveTopBarRows()

    if state.menuOpen then
        if hitMenuPanel(x, y) then
            handleMenuClick(x, y)
            return
        end
        if not hitRegion(x, y, state.ui.menuButton) then
            state.menuOpen = false
        end
    end

    if handleFullscreenMenuButtonClick(x, y) then
        return
    end

    if not state.fullscreen then
        if y == 1 then
            handleTabClick(button, x)
            return
        end

        if y == 2 then
            handleToolbarClick(x)
            return
        end
    end

    local tab = activeTab()
    tab.urlFocus = false
    clearUrlSelection(tab)

    if handleScrollbarClick(button, x, y, tab, topRows) then
        return
    end

    handlePageContentClick(button, x, y, tab, topRows)
end

function handleMouseDrag(button, x, y)
    if state.scrollbarDrag and state.scrollbarDrag.button == button then
        local drag = state.scrollbarDrag
        local tab = drag.tab or activeTab()
        if tab ~= activeTab() then
            state.scrollbarDrag = nil
            return
        end

        local scrollbar = verticalScrollbarMetrics(tab)
        if not scrollbar then
            state.scrollbarDrag = nil
            return
        end

        local row = clamp(y - effectiveTopBarRows(), 1, scrollbar.viewportHeight)
        local travel = scrollbar.viewportHeight - scrollbar.thumbHeight
        if travel <= 0 or scrollbar.maxScroll <= 0 then
            setScroll(0, tab)
            return
        end

        local thumbTop = clamp(row - (drag.grabOffset or 0), 1, travel + 1)
        local ratio = (thumbTop - 1) / travel
        setScroll(math.floor((ratio * scrollbar.maxScroll) + 0.5), tab)
        return
    end

    if state.tabDrag and state.tabDrag.button == button then
        if state.expandedTabIndex then
            return
        end
        if y ~= 1 then
            return
        end

        layoutUi()
        local target = tabIndexAt(x)
        if not target then
            if x < 1 then
                target = 1
            elseif x > state.ui.newTab.x1 then
                target = #state.tabs
            end
        end

        if target and target ~= state.tabDrag.index then
            moveTab(state.tabDrag.index, target)
            state.tabDrag.index = target
            layoutUi()
        end
        return
    end

    if not state.caretMode then
        return
    end
    if button ~= 1 or y <= effectiveTopBarRows() then
        return
    end

    local tab = activeTab()
    if not tab.pageSelection then
        return
    end

    local w = pageContentWidth(tab)
    local lineIndex = clamp(tab.scroll + (y - effectiveTopBarRows()), 1, pageLineCount(tab))
    local column = clamp(x, 1, w)
    tab.pageSelection.endLine = lineIndex
    tab.pageSelection.endCol = column
end

function handleMouseUp(button, _, _)
    if state.tabDrag and state.tabDrag.button == button then
        state.tabDrag = nil
    end
    if state.scrollbarDrag and state.scrollbarDrag.button == button then
        state.scrollbarDrag = nil
    end
end

function handleMouseScroll(direction, _, y)
    if y <= effectiveTopBarRows() then
        return
    end
    local tab = activeTab()
    setScroll(tab.scroll + direction, tab)
end

function focusUrlBar()
    local tab = activeTab()
    tab.urlFocus = true
    tab.urlCursor = #tab.urlInput + 1
    clearUrlSelection(tab)
end

function handleUrlKey(key)
    local tab = activeTab()
    if key == keys.enter then
        navigate(tab.urlInput, true, true, tab)
    elseif key == keys.left then
        local startPos, _ = getUrlSelection(tab)
        if startPos then
            tab.urlCursor = startPos
            clearUrlSelection(tab)
        else
            tab.urlCursor = clamp(tab.urlCursor - 1, 1, #tab.urlInput + 1)
        end
    elseif key == keys.right then
        local _, endPos = getUrlSelection(tab)
        if endPos then
            tab.urlCursor = endPos
            clearUrlSelection(tab)
        else
            tab.urlCursor = clamp(tab.urlCursor + 1, 1, #tab.urlInput + 1)
        end
    elseif key == keys.home then
        tab.urlCursor = 1
        clearUrlSelection(tab)
    elseif key == keys["end"] then
        tab.urlCursor = #tab.urlInput + 1
        clearUrlSelection(tab)
    elseif key == keys.backspace then
        deleteUrlBack()
    elseif key == keys.delete then
        deleteUrlForward()
    elseif key == keys.escape then
        tab.urlFocus = false
        tab.urlInput = tab.currentUrl
        tab.urlCursor = #tab.urlInput + 1
        clearUrlSelection(tab)
    end
end

function handleNavigationKey(key)
    local tab = activeTab()
    if state.caretMode then
        local w = pageContentWidth(tab)
        local maxLine = pageLineCount(tab)
        local selection = tab.pageSelection
        if not selection then
            local startLine = clamp(tab.scroll + 1, 1, maxLine)
            selection = {
                startLine = startLine,
                startCol = 1,
                endLine = startLine,
                endCol = 1,
            }
            tab.pageSelection = selection
        end

        local line = clamp(selection.endLine or 1, 1, maxLine)
        local col = clamp(selection.endCol or 1, 1, w)
        local newLine = line
        local newCol = col

        if key == keys.left then
            newCol = col - 1
            if newCol < 1 then
                newLine = math.max(1, line - 1)
                newCol = w
            end
        elseif key == keys.right then
            newCol = col + 1
            if newCol > w then
                newLine = math.min(maxLine, line + 1)
                newCol = 1
            end
        elseif key == keys.up then
            newLine = line - 1
        elseif key == keys.down then
            newLine = line + 1
        elseif key == keys.pageUp then
            newLine = line - pageHeight()
        elseif key == keys.pageDown then
            newLine = line + pageHeight()
        elseif key == keys.home then
            newCol = 1
        elseif key == keys["end"] then
            newCol = w
        else
            return
        end

        newLine = clamp(newLine, 1, maxLine)
        newCol = clamp(newCol, 1, w)
        if state.shiftDown then
            selection.endLine = newLine
            selection.endCol = newCol
        else
            selection.startLine = newLine
            selection.startCol = newCol
            selection.endLine = newLine
            selection.endCol = newCol
        end

        local visibleTop = tab.scroll + 1
        local visibleBottom = tab.scroll + pageHeight()
        if newLine < visibleTop then
            setScroll(newLine - 1, tab)
        elseif newLine > visibleBottom then
            setScroll(newLine - pageHeight(), tab)
        end
        return
    end

    if key == keys.up then
        setScroll(tab.scroll - 1, tab)
    elseif key == keys.down then
        setScroll(tab.scroll + 1, tab)
    elseif key == keys.pageUp then
        setScroll(tab.scroll - pageHeight(), tab)
    elseif key == keys.pageDown then
        setScroll(tab.scroll + pageHeight(), tab)
    elseif key == keys.home then
        setScroll(0, tab)
    elseif key == keys["end"] then
        setScroll(maxScroll(tab), tab)
    end
end

function selectAllText()
    local tab = activeTab()
    if tab.urlFocus then
        tab.urlSelStart = 1
        tab.urlSelEnd = #tab.urlInput + 1
        tab.urlCursor = #tab.urlInput + 1
        return true
    end

    if tab.focusedFormControl then
        local control, stateEntry = formControl(tab, tab.focusedFormControl)
        if control and isEditableFormControl(control) then
            local value = tostring(stateEntry.value or "")
            stateEntry.cursor = #value + 1
            bumpRenderRevision(tab)
            return true
        end
    end

    if state.caretMode then
        selectAllPageText(tab)
        return true
    end

    return false
end

function copySelectedText()
    local tab = activeTab()
    local text = ""
    if tab.urlFocus then
        text = getSelectedUrlText(tab)
        if text == "" then
            text = tab.urlInput or ""
        end
    elseif tab.focusedFormControl then
        local control, stateEntry = formControl(tab, tab.focusedFormControl)
        if control then
            if control.tag == "input" then
                local inputType = tostring(control.inputType or "text"):lower()
                if inputType == "checkbox" or inputType == "radio" then
                    text = stateEntry.checked and "true" or "false"
                else
                    text = tostring(stateEntry.value or control.defaultValue or "")
                end
            elseif control.tag == "select" then
                local options = control.options or {}
                local index = tonumber(stateEntry.selectedIndex) or control.defaultSelectedIndex or 1
                index = clamp(math.floor(index or 1), 1, math.max(1, #options))
                local option = options[index]
                if option then
                    text = tostring(option.value or option.label or "")
                end
            else
                text = tostring(stateEntry.value or control.defaultValue or "")
            end
        end
    elseif state.caretMode or tab.pageSelection then
        text = getSelectedPageText(tab)
    end

    if text == "" then
        text = trim(tostring(tab.currentUrl or tab.urlInput or ""))
    end

    if text ~= "" then
        state.clipboard = text
        state.localClipboardPendingPaste = true
        return true
    end
    return false
end

function cutSelectedText()
    local tab = activeTab()
    if tab.urlFocus then
        local text = getSelectedUrlText(tab)
        if text == "" then
            return false
        end
        state.clipboard = text
        state.localClipboardPendingPaste = true
        deleteUrlSelection(tab)
        return true
    end

    if tab.focusedFormControl then
        local control, stateEntry = formControl(tab, tab.focusedFormControl)
        if control and isEditableFormControl(control) then
            local text = tostring(stateEntry.value or "")
            if text == "" then
                return false
            end
            state.clipboard = text
            state.localClipboardPendingPaste = true
            stateEntry.value = ""
            stateEntry.cursor = 1
            bumpRenderRevision(tab)
            return true
        end
    end

    if state.caretMode or tab.pageSelection then
        local text = getSelectedPageText(tab)
        if text == "" then
            return false
        end
        state.clipboard = text
        state.localClipboardPendingPaste = true
        return true
    end

    return false
end

function pasteClipboardText()
    local tab = activeTab()
    if state.clipboard == nil or state.clipboard == "" then
        return false
    end

    if tab.urlFocus then
        insertUrlText(state.clipboard)
        state.localClipboardPendingPaste = false
        state.skipNextPaste = true
        return true
    end

    if tab.focusedFormControl then
        local control, stateEntry = formControl(tab, tab.focusedFormControl)
        if control and isEditableFormControl(control) then
            insertIntoFormControl(stateEntry, control, state.clipboard)
            state.localClipboardPendingPaste = false
            state.skipNextPaste = true
            bumpRenderRevision(tab)
            return true
        end
    end

    tab.urlFocus = true
    tab.focusedFormControl = nil
    tab.urlCursor = #tab.urlInput + 1
    clearUrlSelection(tab)
    insertUrlText(state.clipboard)
    state.localClipboardPendingPaste = false
    state.skipNextPaste = true
    return true
end

function handleKeyDown(key, appletContext)
    if key ~= keys.v then
        state.skipNextPaste = false
    end

    if key == keys.leftCtrl or key == keys.rightCtrl then
        state.ctrlDown = true
        return
    end
    if key == keys.leftShift or key == keys.rightShift then
        state.shiftDown = true
        return
    end

    if state.menuOpen and key == keys.escape then
        state.menuOpen = false
        return
    end

    if key == keys.f5 then
        reloadPage()
        return
    end
    if key == keys.f7 then
        state.caretMode = not state.caretMode
        if state.caretMode then
            activeTab().focusedFormControl = nil
        end
        if not state.caretMode then
            for _, tabItem in ipairs(state.tabs) do
                clearPageSelection(tabItem)
            end
        end
        return
    end

    if state.ctrlDown then
        if key == keys.l then
            activeTab().focusedFormControl = nil
            focusUrlBar()
            return
        end
        if key == keys.r then
            reloadPage()
            return
        end
        if key == keys.a then
            selectAllText()
            return
        end
        if key == keys.c then
            copySelectedText()
            return
        end
        if key == keys.x then
            cutSelectedText()
            return
        end
        if key == keys.v then
            pasteClipboardText()
            return
        end
        if key == keys.t then
            local newTabUrl = homePageUrl()
            local tab = newTab(newTabUrl)
            navigate(newTabUrl, true, false, tab)
            tab.urlFocus = true
            tab.urlCursor = #tab.urlInput + 1
            clearUrlSelection(tab)
            return
        end
        if key == keys.w then
            closeActiveTab()
            return
        end
        if key == keys.tab then
            cycleTabs(1)
            return
        end
        if key == keys.q then
            state.running = false
            return
        end
        if key == keys.p then
            printCurrentPage()
            return
        end
        if key == keys.k then
            toggleFullscreen(true)
            return
        end
        if key == keys.left then
            goBack()
            return
        end
        if key == keys.right then
            goForward()
            return
        end
    end

    if appletContext then
        if key == keys.escape then
            if state.fullscreen then
                if not state.seamlessAppletFullscreen then
                    toggleFullscreen()
                end
            else
                state.running = false
            end
        end
        return
    end

    local tab = activeTab()
    if tab.focusedFormControl then
        if handleFocusedFormControlKey(tab, key) then
            bumpRenderRevision(tab)
            return
        end
    end

    if key == keys.tab then
        tab.urlFocus = not tab.urlFocus
        if tab.urlFocus then
            tab.focusedFormControl = nil
            tab.urlCursor = #tab.urlInput + 1
            clearUrlSelection(tab)
        else
            clearUrlSelection(tab)
        end
        return
    end

    if tab.urlFocus then
        handleUrlKey(key)
        return
    end

    if key == keys.escape then
        if state.fullscreen then
            toggleFullscreen()
            return
        end
        state.running = false
        return
    end

    handleNavigationKey(key)
end

function handleKeyUp(key)
    if key == keys.leftCtrl or key == keys.rightCtrl then
        state.ctrlDown = false
    elseif key == keys.leftShift or key == keys.rightShift then
        state.shiftDown = false
    end
end

scheduleAboutUpdateTimer = function()
    if not os.startTimer then
        return
    end

    local update = state.aboutUpdate
    local tab = activeTab()
    local intervalMs = tonumber(tab.aboutUpdateIntervalMs)
    local currentUrl = trim(tab.currentUrl or ""):lower()
    local shouldUpdate = (intervalMs and intervalMs > 0)
        and startsWith(currentUrl, "about:")
        and not tab.loading
        and not state.modal.open

    if not shouldUpdate then
        update.timer = nil
        update.tabIndex = nil
        update.intervalMs = nil
        return
    end

    intervalMs = math.floor(intervalMs + 0.5)
    if intervalMs < 1 then
        update.timer = nil
        update.tabIndex = nil
        update.intervalMs = nil
        return
    end

    if update.timer and update.tabIndex == state.activeTab and update.intervalMs == intervalMs then
        return
    end

    update.timer = nil
    update.tabIndex = state.activeTab
    update.intervalMs = intervalMs
    update.timer = os.startTimer(intervalMs / 1000)
end

scheduleAnimationTick = function()
    if not os.startTimer then
        return
    end
    if state.animationTimer then
        return
    end
    state.animationTimer = os.startTimer(ANIMATION_TICK_SECONDS)
end

function handleTimer(timerId)
    if state.animationTimer and timerId == state.animationTimer then
        state.animationTimer = nil
        scheduleAnimationTick()
        if state.running then
            draw()
        end
        return
    end

    local aboutUpdate = state.aboutUpdate
    if aboutUpdate.timer and timerId == aboutUpdate.timer then
        aboutUpdate.timer = nil
        aboutUpdate.tabIndex = nil
        aboutUpdate.intervalMs = nil

        local tab = activeTab()
        local currentUrl = trim(tab.currentUrl or ""):lower()
        if startsWith(currentUrl, "about:") and not tab.loading and not state.modal.open then
            refreshCurrentDocumentWithoutNavigation(tab)
        end
        if scheduleAboutUpdateTimer then
            scheduleAboutUpdateTimer()
        end
    end
end

function handleChar(character)
    local byte = character and string.byte(character, 1) or nil
    if byte and byte >= 1 and byte <= 31 then
        if byte == 1 then
            selectAllText()
        elseif byte == 3 then
            copySelectedText()
        elseif byte == 24 then
            cutSelectedText()
        elseif byte == 22 then
            pasteClipboardText()
        end
        return
    end

    local tab = activeTab()
    if tab.urlFocus then
        insertUrlText(character)
        return
    end

    if handleFocusedFormControlChar(tab, character) then
        bumpRenderRevision(tab)
    end
end

function resolvePasteText(text)
    local pasteText = text
    if state.localClipboardPendingPaste and state.clipboard ~= "" then
        pasteText = state.clipboard
        state.localClipboardPendingPaste = false
    end
    return pasteText
end

function handlePaste(text)
    if state.skipNextPaste then
        state.skipNextPaste = false
        return
    end
    local tab = activeTab()
    local pasteText = resolvePasteText(text)
    if tab.urlFocus then
        if pasteText and pasteText ~= "" then
            insertUrlText(pasteText)
            state.clipboard = pasteText
        end
        return
    end
    if handleFocusedFormControlPaste(tab, pasteText) then
        bumpRenderRevision(tab)
        if pasteText and pasteText ~= "" then
            state.clipboard = pasteText
        end
        return
    end

    if pasteText and pasteText ~= "" then
        tab.urlFocus = true
        tab.focusedFormControl = nil
        tab.urlCursor = #tab.urlInput + 1
        clearUrlSelection(tab)
        insertUrlText(pasteText)
        state.clipboard = pasteText
    end
end

