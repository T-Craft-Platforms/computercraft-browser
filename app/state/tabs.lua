return function(deps)
    local state = deps.state
    local clamp = deps.clamp
    local term = deps.term
    local effectiveTopBarRows = deps.effectiveTopBarRows
    local homePageUrl = deps.homePageUrl
    local createTab = deps.createTab
    local createEmptyLine = deps.createEmptyLine
    local buildDocument = deps.buildDocument
    local currentDefaultBackgroundColorValue = deps.currentDefaultBackgroundColorValue
    local currentDefaultForegroundColorValue = deps.currentDefaultForegroundColorValue
    local renderDocumentWindowLines = deps.renderDocumentWindowLines
    local pageOverflowYFromDocument = deps.pageOverflowYFromDocument
    local getStopAppletForTab = deps.getStopAppletForTab or function()
        return nil
    end
    local getFlushPausedAppletQueue = deps.getFlushPausedAppletQueue or function()
        return nil
    end
    local PAUSED_APPLET_EVENT_MAX = deps.PAUSED_APPLET_EVENT_MAX or 512

    local api = {}

    function api.activeTab()
        if #state.tabs < 1 then
            state.tabs[1] = createTab(homePageUrl())
            state.activeTab = 1
        end
        state.activeTab = clamp(state.activeTab, 1, #state.tabs)
        return state.tabs[state.activeTab]
    end

    function api.clearUrlSelection(tab)
        local target = tab or api.activeTab()
        target.urlSelStart = nil
        target.urlSelEnd = nil
    end

    function api.getUrlSelection(tab)
        local target = tab or api.activeTab()
        if target.urlSelStart == nil or target.urlSelEnd == nil then
            return nil, nil
        end

        local maxPos = #target.urlInput + 1
        local startPos = clamp(target.urlSelStart, 1, maxPos)
        local endPos = clamp(target.urlSelEnd, 1, maxPos)
        if startPos > endPos then
            startPos, endPos = endPos, startPos
        end
        if startPos == endPos then
            return nil, nil
        end
        return startPos, endPos
    end

    function api.getSelectedUrlText(tab)
        local target = tab or api.activeTab()
        local startPos, endPos = api.getUrlSelection(target)
        if not startPos then
            return ""
        end
        return target.urlInput:sub(startPos, endPos - 1)
    end

    function api.deleteUrlSelection(tab)
        local target = tab or api.activeTab()
        local startPos, endPos = api.getUrlSelection(target)
        if not startPos then
            return false
        end

        local before = target.urlInput:sub(1, startPos - 1)
        local after = target.urlInput:sub(endPos)
        target.urlInput = before .. after
        target.urlCursor = startPos
        api.clearUrlSelection(target)
        return true
    end

    function api.clearPageSelection(tab)
        local target = tab or api.activeTab()
        target.pageSelection = nil
    end

    function api.bumpRenderRevision(tab)
        local target = tab or api.activeTab()
        target.renderRevision = (target.renderRevision or 0) + 1
    end

    function api.pageLineCount(tab)
        local target = tab or api.activeTab()
        local count = tonumber(target.pageContentHeight)
        if not count then
            count = #target.pageLines
        end
        return math.max(1, math.floor(count or 1))
    end

    function api.normalizedPageSelection(tab)
        local target = tab or api.activeTab()
        local selection = target.pageSelection
        if not selection then
            return nil
        end

        local startLine = selection.startLine or 1
        local startCol = selection.startCol or 1
        local endLine = selection.endLine or startLine
        local endCol = selection.endCol or startCol

        if (startLine > endLine) or (startLine == endLine and startCol > endCol) then
            startLine, endLine = endLine, startLine
            startCol, endCol = endCol, startCol
        end

        return {
            startLine = startLine,
            startCol = startCol,
            endLine = endLine,
            endCol = endCol,
        }
    end

    function api.pageSelectionContains(selection, lineIndex, column)
        if not selection then
            return false
        end
        if lineIndex < selection.startLine or lineIndex > selection.endLine then
            return false
        end
        if lineIndex == selection.startLine and column < selection.startCol then
            return false
        end
        if lineIndex == selection.endLine and column > selection.endCol then
            return false
        end
        return true
    end

    function api.setPageSelection(tab, startLine, startCol, endLine, endCol)
        local target = tab or api.activeTab()
        local w = math.max(1, target.viewportWidth or 1)
        local maxLine = api.pageLineCount(target)

        target.pageSelection = {
            startLine = clamp(startLine, 1, maxLine),
            startCol = clamp(startCol, 1, w),
            endLine = clamp(endLine, 1, maxLine),
            endCol = clamp(endCol, 1, w),
        }
    end

    function api.selectAllPageText(tab)
        local target = tab or api.activeTab()
        local totalLines = api.pageLineCount(target)
        if totalLines < 1 then
            api.clearPageSelection(target)
            return
        end

        local width = math.max(1, target.viewportWidth or 1)
        api.setPageSelection(target, 1, 1, totalLines, width)
    end

    function api.getSelectedPageText(tab)
        local target = tab or api.activeTab()
        local selection = api.normalizedPageSelection(target)
        if not selection then
            return ""
        end

        local w = math.max(1, target.viewportWidth or 1)
        local sourceLines = target.pageLines or {}
        local missingRange = false
        for lineIndex = selection.startLine, selection.endLine do
            if sourceLines[lineIndex] == nil then
                missingRange = true
                break
            end
        end
        if missingRange and target.document then
            local requestedCount = selection.endLine - selection.startLine + 1
            local windowLines = select(
                1,
                renderDocumentWindowLines(
                    target.document,
                    w,
                    selection.startLine,
                    requestedCount,
                    target.formState,
                    target.focusedFormControl
                )
            )
            if type(windowLines) == "table" then
                sourceLines = windowLines
            end
        end

        local parts = {}
        for lineIndex = selection.startLine, selection.endLine do
            local startCol = (lineIndex == selection.startLine) and selection.startCol or 1
            local endCol = (lineIndex == selection.endLine) and selection.endCol or w
            startCol = clamp(startCol, 1, w)
            endCol = clamp(endCol, 1, w)
            if endCol < startCol then
                startCol, endCol = endCol, startCol
            end

            local line = sourceLines[lineIndex] or target.pageLines[lineIndex]
            local chars = {}
            for x = startCol, endCol do
                chars[#chars + 1] = (line and line.chars and line.chars[x]) or " "
            end
            parts[#parts + 1] = table.concat(chars):gsub("%s+$", "")
        end

        return table.concat(parts, "\n")
    end

    function api.pageHeight()
        local _, h = term.getSize()
        return math.max(1, h - effectiveTopBarRows())
    end

    function api.pageContentWidth(tab)
        local target = tab or api.activeTab()
        local w, _ = term.getSize()
        return clamp(target.viewportWidth or w, 1, w)
    end

    function api.pageOverflowY(tab)
        local target = tab or api.activeTab()
        local mode = pageOverflowYFromDocument(target and target.document)
        if mode == "hidden" or mode == "scroll" or mode == "auto" then
            return mode
        end
        return "visible"
    end

    function api.maxScroll(tab)
        local target = tab or api.activeTab()
        if api.pageOverflowY(target) == "hidden" then
            return 0
        end
        return math.max(0, api.pageLineCount(target) - api.pageHeight())
    end

    function api.setScroll(value, tab)
        local target = tab or api.activeTab()
        target.scroll = clamp(value, 0, api.maxScroll(target))
    end

    function api.canGoBack(tab)
        local target = tab or api.activeTab()
        return target.historyIndex > 1
    end

    function api.canGoForward(tab)
        local target = tab or api.activeTab()
        return target.historyIndex > 0 and target.historyIndex < #target.history
    end

    function api.pushHistory(tab, url)
        local target = tab or api.activeTab()
        for i = #target.history, target.historyIndex + 1, -1 do
            target.history[i] = nil
        end
        table.insert(target.history, url)
        target.historyIndex = #target.history
    end

    function api.collapseExpandedTab()
        state.expandedTabIndex = nil
    end

    function api.toggleExpandedTab(index)
        if state.expandedTabIndex == index then
            api.collapseExpandedTab()
        else
            state.expandedTabIndex = index
        end
    end

    function api.activateTab(index)
        if #state.tabs < 1 then
            return
        end
        state.menuOpen = false
        state.activeTab = clamp(index, 1, #state.tabs)
        state.tabDrag = nil
        state.scrollbarDrag = nil
        if state.expandedTabIndex and state.expandedTabIndex ~= state.activeTab then
            api.collapseExpandedTab()
        end
        api.syncAppletWindowVisibility()
        local flushPausedAppletQueue = getFlushPausedAppletQueue()
        if flushPausedAppletQueue then
            flushPausedAppletQueue(api.activeTab(), PAUSED_APPLET_EVENT_MAX)
        end
    end

    function api.moveTab(fromIndex, toIndex)
        if fromIndex == toIndex then
            return
        end
        if fromIndex < 1 or fromIndex > #state.tabs then
            return
        end
        if toIndex < 1 or toIndex > #state.tabs then
            return
        end

        local moved = table.remove(state.tabs, fromIndex)
        table.insert(state.tabs, toIndex, moved)

        if state.activeTab == fromIndex then
            state.activeTab = toIndex
        elseif fromIndex < state.activeTab and toIndex >= state.activeTab then
            state.activeTab = state.activeTab - 1
        elseif fromIndex > state.activeTab and toIndex <= state.activeTab then
            state.activeTab = state.activeTab + 1
        end

        local expanded = state.expandedTabIndex
        if expanded then
            if expanded == fromIndex then
                state.expandedTabIndex = toIndex
            elseif fromIndex < expanded and toIndex >= expanded then
                state.expandedTabIndex = expanded - 1
            elseif fromIndex > expanded and toIndex <= expanded then
                state.expandedTabIndex = expanded + 1
            end
        end
    end

    function api.newTab(initialUrl)
        local tab = createTab(initialUrl or homePageUrl())
        table.insert(state.tabs, tab)
        api.collapseExpandedTab()
        api.activateTab(#state.tabs)
        return tab
    end

    function api.closeTab(index)
        local targetIndex = clamp(index or state.activeTab, 1, #state.tabs)
        if #state.tabs <= 1 then
            local tab = api.activeTab()
            local stopAppletForTab = getStopAppletForTab()
            if stopAppletForTab then
                stopAppletForTab(tab, true)
            end
            tab.currentUrl = "about:blank"
            tab.urlInput = "about:blank"
            tab.urlCursor = #tab.urlInput + 1
            tab.urlOffset = 0
            api.clearUrlSelection(tab)
            tab.urlFocus = false
            tab.scroll = 0
            tab.history = { "about:blank" }
            tab.historyIndex = 1
            tab.document = buildDocument("<html><body></body></html>", "about:blank")
            tab.pageDefaultBackground = tab.document.defaultBackground or currentDefaultBackgroundColorValue()
            tab.pageDefaultForeground = tab.document.defaultForeground
                or currentDefaultForegroundColorValue(tab.pageDefaultBackground)
            tab.pageLines = { createEmptyLine() }
            tab.pageContentHeight = 1
            tab.pageWindowStart = 1
            tab.pageWindowEnd = 1
            tab.renderRevision = 0
            tab.lastRenderSignature = nil
            tab.viewportWidth = 1
            tab.showVerticalScrollbar = false
            api.clearPageSelection(tab)
            tab.formState = {}
            tab.formMeta = nil
            tab.focusedFormControl = nil
            tab.loading = false
            tab.status = ""
            tab.aboutUpdateIntervalMs = nil
            tab.settingsStickyStatus = nil
            tab.pendingApplet = nil
            tab.applet = nil
            state.tabDrag = nil
            state.scrollbarDrag = nil
            state.menuOpen = false
            api.collapseExpandedTab()
            return
        end

        local removedTab = state.tabs[targetIndex]
        local stopAppletForTab = getStopAppletForTab()
        if removedTab and stopAppletForTab then
            stopAppletForTab(removedTab, true)
        end
        table.remove(state.tabs, targetIndex)
        if targetIndex < state.activeTab then
            state.activeTab = state.activeTab - 1
        elseif targetIndex == state.activeTab and state.activeTab > #state.tabs then
            state.activeTab = #state.tabs
        end
        state.activeTab = clamp(state.activeTab, 1, #state.tabs)
        state.tabDrag = nil
        state.scrollbarDrag = nil
        state.menuOpen = false

        local expanded = state.expandedTabIndex
        if expanded then
            if targetIndex == expanded then
                api.collapseExpandedTab()
            elseif targetIndex < expanded then
                state.expandedTabIndex = expanded - 1
            end
        end
    end

    function api.closeActiveTab()
        api.closeTab(state.activeTab)
    end

    function api.cycleTabs(direction)
        if #state.tabs <= 1 then
            return
        end
        local index = state.activeTab + direction
        if index < 1 then
            index = #state.tabs
        elseif index > #state.tabs then
            index = 1
        end
        api.activateTab(index)
    end

    function api.syncAppletWindowVisibility()
        local tabCount = #state.tabs
        if tabCount < 1 then
            return
        end

        local activeIndex = clamp(state.activeTab, 1, tabCount)
        local showActive = not state.menuOpen and not state.modal.open

        for index = 1, tabCount do
            local tab = state.tabs[index]
            local applet = tab and tab.applet or nil
            local windowHandle = applet and applet.window or nil
            if windowHandle and windowHandle.setVisible then
                local shouldShow = showActive and index == activeIndex and applet.running == true
                pcall(windowHandle.setVisible, shouldShow and true or false)
            end
        end
    end

    return api
end
