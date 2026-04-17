local APP_TITLE = "CC Browser"

local function getScriptDir()
    if shell and shell.getRunningProgram and fs and fs.getDir then
        local running = shell.getRunningProgram()
        if running and running ~= "" then
            return fs.getDir(running)
        end
    end
    return "/src/browser"
end

local SCRIPT_DIR = getScriptDir()

local function loadModule(relativePath)
    return dofile(fs.combine(SCRIPT_DIR, relativePath))
end

local core = loadModule("lib/core.lua")
local createNetwork = loadModule("lib/network.lua")
local createHtml = loadModule("lib/html.lua")
local createContent = loadModule("lib/content.lua")
local createUi = loadModule("ui/view.lua")

local network = createNetwork(core, {
    aboutPagesDir = fs.combine(SCRIPT_DIR, "about-pages"),
})
local html = createHtml(core)
local content = createContent({
    core = core,
    html = html,
    network = network,
})

local clamp = core.clamp
local trim = core.trim
local escapeHtml = core.escapeHtml
local normalizeInputUrl = core.normalizeInputUrl
local getHeader = core.getHeader

local fetchTextResource = network.fetchTextResource
local makeErrorPage = network.makeErrorPage
local looksLikeHtml = network.looksLikeHtml

local createEmptyLine = content.createEmptyLine
local buildDocument = content.buildDocument
local renderDocumentLines = content.renderDocumentLines

local TOP_BAR_ROWS = 2

local function createTab(initialUrl)
    local startingUrl = initialUrl or "about:blank"
    return {
        currentUrl = startingUrl,
        urlInput = startingUrl,
        urlCursor = #startingUrl + 1,
        urlOffset = 0,
        urlSelStart = nil,
        urlSelEnd = nil,
        urlFocus = false,
        scroll = 0,
        history = {},
        historyIndex = 0,
        document = nil,
        pageLines = { createEmptyLine() },
        pageSelection = nil,
        loading = false,
        status = "",
    }
end

local state = {
    tabs = { createTab("about:help") },
    activeTab = 1,
    tabDrag = nil,
    caretMode = false,
    clipboard = "",
    skipNextPaste = false,
    lastTabClick = {
        index = nil,
        button = nil,
        at = 0,
    },
    tabNameReveal = nil,
    tabRevealTimer = nil,
    running = true,
    ctrlDown = false,
    shiftDown = false,
    ui = {
        tabs = {},
        tabClose = {},
        closeBrowser = { x1 = 1, x2 = 1, y = 1 },
        newTab = { x1 = 1, x2 = 1, y = 1 },
        back = { x1 = 1, x2 = 3, y = 2 },
        forward = { x1 = 5, x2 = 7, y = 2 },
        reload = { x1 = 9, x2 = 11, y = 2 },
        url = { x1 = 13, x2 = 13, y = 2 },
    },
}

local function activeTab()
    if #state.tabs < 1 then
        state.tabs[1] = createTab("about:blank")
        state.activeTab = 1
    end
    state.activeTab = clamp(state.activeTab, 1, #state.tabs)
    return state.tabs[state.activeTab]
end

local function clearUrlSelection(tab)
    local target = tab or activeTab()
    target.urlSelStart = nil
    target.urlSelEnd = nil
end

local function getUrlSelection(tab)
    local target = tab or activeTab()
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

local function getSelectedUrlText(tab)
    local target = tab or activeTab()
    local startPos, endPos = getUrlSelection(target)
    if not startPos then
        return ""
    end
    return target.urlInput:sub(startPos, endPos - 1)
end

local function deleteUrlSelection(tab)
    local target = tab or activeTab()
    local startPos, endPos = getUrlSelection(target)
    if not startPos then
        return false
    end

    local before = target.urlInput:sub(1, startPos - 1)
    local after = target.urlInput:sub(endPos)
    target.urlInput = before .. after
    target.urlCursor = startPos
    clearUrlSelection(target)
    return true
end

local function clearPageSelection(tab)
    local target = tab or activeTab()
    target.pageSelection = nil
end

local function normalizedPageSelection(tab)
    local target = tab or activeTab()
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

local function pageSelectionContains(selection, lineIndex, column)
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

local function setPageSelection(tab, startLine, startCol, endLine, endCol)
    local target = tab or activeTab()
    local w, _ = term.getSize()
    local maxLine = math.max(1, #target.pageLines)

    target.pageSelection = {
        startLine = clamp(startLine, 1, maxLine),
        startCol = clamp(startCol, 1, w),
        endLine = clamp(endLine, 1, maxLine),
        endCol = clamp(endCol, 1, w),
    }
end

local function selectAllPageText(tab)
    local target = tab or activeTab()
    if #target.pageLines < 1 then
        clearPageSelection(target)
        return
    end

    local w, _ = term.getSize()
    setPageSelection(target, 1, 1, math.max(1, #target.pageLines), w)
end

local function getSelectedPageText(tab)
    local target = tab or activeTab()
    local selection = normalizedPageSelection(target)
    if not selection then
        return ""
    end

    local w, _ = term.getSize()
    local parts = {}
    for lineIndex = selection.startLine, selection.endLine do
        local startCol = (lineIndex == selection.startLine) and selection.startCol or 1
        local endCol = (lineIndex == selection.endLine) and selection.endCol or w
        startCol = clamp(startCol, 1, w)
        endCol = clamp(endCol, 1, w)
        if endCol < startCol then
            startCol, endCol = endCol, startCol
        end

        local line = target.pageLines[lineIndex]
        local chars = {}
        for x = startCol, endCol do
            chars[#chars + 1] = (line and line.chars and line.chars[x]) or " "
        end
        parts[#parts + 1] = table.concat(chars):gsub("%s+$", "")
    end

    return table.concat(parts, "\n")
end

local function pageHeight()
    local _, h = term.getSize()
    return math.max(1, h - TOP_BAR_ROWS)
end

local function maxScroll(tab)
    local target = tab or activeTab()
    return math.max(0, #target.pageLines - pageHeight())
end

local function setScroll(value, tab)
    local target = tab or activeTab()
    target.scroll = clamp(value, 0, maxScroll(target))
end

local function canGoBack(tab)
    local target = tab or activeTab()
    return target.historyIndex > 1
end

local function canGoForward(tab)
    local target = tab or activeTab()
    return target.historyIndex > 0 and target.historyIndex < #target.history
end

local function pushHistory(tab, url)
    local target = tab or activeTab()
    for i = #target.history, target.historyIndex + 1, -1 do
        target.history[i] = nil
    end
    table.insert(target.history, url)
    target.historyIndex = #target.history
end

local function activateTab(index)
    if #state.tabs < 1 then
        return
    end
    state.activeTab = clamp(index, 1, #state.tabs)
    state.tabDrag = nil
end

local function moveTab(fromIndex, toIndex)
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
    state.tabNameReveal = nil
end

local function newTab(initialUrl)
    local tab = createTab(initialUrl or "about:blank")
    table.insert(state.tabs, tab)
    activateTab(#state.tabs)
    return tab
end

local function closeTab(index)
    local targetIndex = clamp(index or state.activeTab, 1, #state.tabs)
    if #state.tabs <= 1 then
        local tab = activeTab()
        tab.currentUrl = "about:blank"
        tab.urlInput = "about:blank"
        tab.urlCursor = #tab.urlInput + 1
        tab.urlOffset = 0
        clearUrlSelection(tab)
        tab.urlFocus = false
        tab.scroll = 0
        tab.history = { "about:blank" }
        tab.historyIndex = 1
        tab.document = buildDocument("<html><body></body></html>", "about:blank")
        tab.pageLines = { createEmptyLine() }
        clearPageSelection(tab)
        tab.loading = false
        tab.status = ""
        state.tabDrag = nil
        state.tabNameReveal = nil
        return
    end

    table.remove(state.tabs, targetIndex)
    if targetIndex < state.activeTab then
        state.activeTab = state.activeTab - 1
    elseif targetIndex == state.activeTab and state.activeTab > #state.tabs then
        state.activeTab = #state.tabs
    end
    state.activeTab = clamp(state.activeTab, 1, #state.tabs)
    state.tabDrag = nil
    state.tabNameReveal = nil
end

local function closeActiveTab()
    closeTab(state.activeTab)
end

local function cycleTabs(direction)
    if #state.tabs <= 1 then
        return
    end
    local index = state.activeTab + direction
    if index < 1 then
        index = #state.tabs
    elseif index > #state.tabs then
        index = 1
    end
    activateTab(index)
end

local function tabTitle(tab)
    if tab.loading then
        return "Loading..."
    end

    local title = trim(tab.document and tab.document.title or "")
    if title ~= "" then
        return title
    end

    local url = trim(tab.currentUrl or tab.urlInput or "")
    if url ~= "" then
        return url
    end

    return "New Tab"
end

local ui = createUi({
    state = state,
    clamp = clamp,
    topBarRows = TOP_BAR_ROWS,
    activeTab = activeTab,
    canGoBack = canGoBack,
    canGoForward = canGoForward,
    tabTitle = tabTitle,
    getUrlSelection = getUrlSelection,
    normalizedPageSelection = normalizedPageSelection,
    pageSelectionContains = pageSelectionContains,
})

local layoutUi = ui.layoutUi
local tabIndexAt = ui.tabIndexAt
local tabCloseIndexAt = ui.tabCloseIndexAt
local revealTabName = ui.revealTabName
local draw = ui.draw

local function renderDocument(tab)
    local target = tab or activeTab()
    if not target.document then
        target.pageLines = { createEmptyLine() }
        setScroll(0, target)
        return
    end

    local w, _ = term.getSize()
    target.pageLines = renderDocumentLines(target.document, w)
    setScroll(target.scroll, target)
end

local function hitRegion(x, y, region)
    if not region then
        return false
    end
    local regionY = region.y or 1
    return y == regionY and x >= region.x1 and x <= region.x2
end

local function loadDocumentWithAbort(tab, normalized, allowFallback)
    if not parallel or not parallel.waitForAny then
        local body, finalUrl, headers, err = fetchTextResource(normalized, allowFallback)
        if not body then
            finalUrl = normalized
            body = makeErrorPage(finalUrl, err or "Unknown error")
            headers = { ["Content-Type"] = "text/html" }
        end

        local contentType = getHeader(headers, "Content-Type") or ""
        if not looksLikeHtml(body, contentType) then
            body = "<html><body><pre>" .. escapeHtml(body) .. "</pre></body></html>"
        end

        return {
            finalUrl = finalUrl,
            document = buildDocument(body, finalUrl),
        }, false
    end

    local result = nil
    local done = false
    local aborted = false

    local function loadTask()
        local ok, errMsg = pcall(function()
            local body, finalUrl, headers, err = fetchTextResource(normalized, allowFallback)
            if not body then
                finalUrl = normalized
                body = makeErrorPage(finalUrl, err or "Unknown error")
                headers = { ["Content-Type"] = "text/html" }
            end

            local contentType = getHeader(headers, "Content-Type") or ""
            if not looksLikeHtml(body, contentType) then
                body = "<html><body><pre>" .. escapeHtml(body) .. "</pre></body></html>"
            end

            result = {
                finalUrl = finalUrl,
                document = buildDocument(body, finalUrl),
            }
        end)

        if not ok then
            local safeError = tostring(errMsg)
            local finalUrl = normalized
            local body = makeErrorPage(finalUrl, safeError)
            result = {
                finalUrl = finalUrl,
                document = buildDocument(body, finalUrl),
            }
        end

        done = true
    end

    local function watchTask()
        while not done do
            local event = { os.pullEvent() }
            local name = event[1]
            if name == "mouse_click" then
                local x = event[3]
                local y = event[4]
                if tab == activeTab() and hitRegion(x, y, state.ui.reload) then
                    aborted = true
                    return
                end
            elseif name == "key" then
                if event[2] == keys.escape then
                    aborted = true
                    return
                end
            elseif name == "term_resize" then
                renderDocument(activeTab())
                draw()
            end
        end
    end

    parallel.waitForAny(loadTask, watchTask)
    return result, aborted
end

local function navigate(rawInput, addToHistory, allowFallback, tab)
    local target = tab or activeTab()
    local normalized, inferred = normalizeInputUrl(rawInput)

    target.loading = true
    target.status = "Loading " .. normalized
    target.urlInput = normalized
    target.urlCursor = #target.urlInput + 1
    target.urlOffset = 0
    clearUrlSelection(target)
    draw()

    local result, aborted = loadDocumentWithAbort(target, normalized, allowFallback or inferred)
    target.loading = false
    if aborted then
        target.status = "Load aborted"
        draw()
        return false
    end

    local finalUrl = normalized
    local document = nil
    if result then
        finalUrl = result.finalUrl or finalUrl
        if result.document then
            document = result.document
        end
    end
    if not document then
        document = buildDocument(makeErrorPage(normalized, "Unknown error"), normalized)
    end

    target.document = document
    target.currentUrl = finalUrl
    target.urlInput = finalUrl
    target.urlCursor = #target.urlInput + 1
    target.urlOffset = 0
    target.status = target.document.title or ""
    target.urlFocus = false
    clearUrlSelection(target)
    clearPageSelection(target)

    if addToHistory then
        pushHistory(target, finalUrl)
    elseif target.historyIndex > 0 then
        target.history[target.historyIndex] = finalUrl
    else
        pushHistory(target, finalUrl)
    end

    target.scroll = 0
    renderDocument(target)
    draw()
    return true
end

local function goBack()
    local tab = activeTab()
    if not canGoBack(tab) then
        return
    end
    tab.historyIndex = tab.historyIndex - 1
    navigate(tab.history[tab.historyIndex], false, false, tab)
end

local function goForward()
    local tab = activeTab()
    if not canGoForward(tab) then
        return
    end
    tab.historyIndex = tab.historyIndex + 1
    navigate(tab.history[tab.historyIndex], false, false, tab)
end

local function reloadPage()
    local tab = activeTab()
    if tab.loading then
        return
    end
    if not tab.currentUrl then
        return
    end
    navigate(tab.currentUrl, false, false, tab)
end

local function insertUrlText(text)
    local tab = activeTab()
    if not tab.urlFocus then
        return
    end
    deleteUrlSelection(tab)
    local before = tab.urlInput:sub(1, tab.urlCursor - 1)
    local after = tab.urlInput:sub(tab.urlCursor)
    tab.urlInput = before .. text .. after
    tab.urlCursor = tab.urlCursor + #text
    clearUrlSelection(tab)
end

local function deleteUrlBack()
    local tab = activeTab()
    if deleteUrlSelection(tab) then
        return
    end
    if tab.urlCursor <= 1 then
        return
    end
    local before = tab.urlInput:sub(1, tab.urlCursor - 2)
    local after = tab.urlInput:sub(tab.urlCursor)
    tab.urlInput = before .. after
    tab.urlCursor = tab.urlCursor - 1
end

local function deleteUrlForward()
    local tab = activeTab()
    if deleteUrlSelection(tab) then
        return
    end
    if tab.urlCursor > #tab.urlInput then
        return
    end
    local before = tab.urlInput:sub(1, tab.urlCursor - 1)
    local after = tab.urlInput:sub(tab.urlCursor + 1)
    tab.urlInput = before .. after
end

local function handleTabClick(button, x)
    if hitRegion(x, 1, state.ui.closeBrowser) then
        state.running = false
        return
    end

    if hitRegion(x, 1, state.ui.newTab) then
        local tab = newTab("about:blank")
        navigate("about:blank", true, false, tab)
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
        return
    end

    activateTab(index)
    clearUrlSelection(activeTab())
    local now = os.clock()
    local wasDoubleClick = button == 1
        and state.lastTabClick.button == button
        and state.lastTabClick.index == index
        and (now - (state.lastTabClick.at or 0)) <= 0.35
    state.lastTabClick = {
        index = index,
        button = button,
        at = now,
    }

    if wasDoubleClick then
        revealTabName(index)
    end

    if button == 1 then
        state.tabDrag = { button = button, index = index }
    end
end

local function handleToolbarClick(x)
    local tab = activeTab()
    if hitRegion(x, 2, state.ui.back) then
        goBack()
        return
    end
    if hitRegion(x, 2, state.ui.forward) then
        goForward()
        return
    end
    if hitRegion(x, 2, state.ui.reload) then
        reloadPage()
        return
    end
    if hitRegion(x, 2, state.ui.url) then
        tab.urlFocus = true
        local pos = tab.urlOffset + (x - state.ui.url.x1) + 1
        tab.urlCursor = clamp(pos, 1, #tab.urlInput + 1)
        clearUrlSelection(tab)
        return
    end
    tab.urlFocus = false
    clearUrlSelection(tab)
end

local function handleMouseClick(button, x, y)
    layoutUi()

    if y == 1 then
        handleTabClick(button, x)
        return
    end

    if y == 2 then
        handleToolbarClick(x)
        return
    end

    local tab = activeTab()
    tab.urlFocus = false
    clearUrlSelection(tab)

    local w, _ = term.getSize()
    local lineIndex = clamp(tab.scroll + (y - TOP_BAR_ROWS), 1, math.max(1, #tab.pageLines))
    local column = clamp(x, 1, w)
    if state.caretMode then
        if button == 1 then
            setPageSelection(tab, lineIndex, column, lineIndex, column)
        end
        return
    end

    clearPageSelection(tab)
    local line = tab.pageLines[lineIndex]
    local href = line and line.links and line.links[x] or nil
    if href then
        navigate(href, true, false, tab)
    end
end

local function handleMouseDrag(button, x, y)
    if state.tabDrag and state.tabDrag.button == button then
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
    if button ~= 1 or y <= TOP_BAR_ROWS then
        return
    end

    local tab = activeTab()
    if not tab.pageSelection then
        return
    end

    local w, _ = term.getSize()
    local lineIndex = clamp(tab.scroll + (y - TOP_BAR_ROWS), 1, math.max(1, #tab.pageLines))
    local column = clamp(x, 1, w)
    tab.pageSelection.endLine = lineIndex
    tab.pageSelection.endCol = column
end

local function handleMouseUp(button, _, _)
    if state.tabDrag and state.tabDrag.button == button then
        state.tabDrag = nil
    end
end

local function handleMouseScroll(direction, _, y)
    if y <= TOP_BAR_ROWS then
        return
    end
    local tab = activeTab()
    setScroll(tab.scroll + direction, tab)
end

local function focusUrlBar()
    local tab = activeTab()
    tab.urlFocus = true
    tab.urlCursor = #tab.urlInput + 1
    clearUrlSelection(tab)
end

local function handleUrlKey(key)
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

local function handleNavigationKey(key)
    local tab = activeTab()
    if state.caretMode then
        local w, _ = term.getSize()
        local maxLine = math.max(1, #tab.pageLines)
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

local function selectAllText()
    local tab = activeTab()
    if tab.urlFocus then
        tab.urlSelStart = 1
        tab.urlSelEnd = #tab.urlInput + 1
        tab.urlCursor = #tab.urlInput + 1
        return true
    end

    if state.caretMode then
        selectAllPageText(tab)
        return true
    end

    return false
end

local function copySelectedText()
    local tab = activeTab()
    local text = ""
    if tab.urlFocus then
        text = getSelectedUrlText(tab)
    elseif state.caretMode then
        text = getSelectedPageText(tab)
    end

    if text ~= "" then
        state.clipboard = text
        return true
    end
    return false
end

local function cutSelectedText()
    local tab = activeTab()
    if tab.urlFocus then
        local text = getSelectedUrlText(tab)
        if text == "" then
            return false
        end
        state.clipboard = text
        deleteUrlSelection(tab)
        return true
    end

    if state.caretMode then
        local text = getSelectedPageText(tab)
        if text == "" then
            return false
        end
        state.clipboard = text
        return true
    end

    return false
end

local function pasteClipboardText()
    local tab = activeTab()
    if not tab.urlFocus then
        return false
    end
    if state.clipboard == nil or state.clipboard == "" then
        return false
    end

    insertUrlText(state.clipboard)
    state.skipNextPaste = true
    return true
end

local function handleKeyDown(key)
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

    if key == keys.f5 then
        reloadPage()
        return
    end
    if key == keys.f7 then
        state.caretMode = not state.caretMode
        if not state.caretMode then
            for _, tabItem in ipairs(state.tabs) do
                clearPageSelection(tabItem)
            end
        end
        return
    end

    if state.ctrlDown then
        if key == keys.l then
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
            local tab = newTab("about:blank")
            navigate("about:blank", true, false, tab)
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
        if key == keys.left then
            goBack()
            return
        end
        if key == keys.right then
            goForward()
            return
        end
    end

    local tab = activeTab()
    if key == keys.tab then
        tab.urlFocus = not tab.urlFocus
        if tab.urlFocus then
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
        state.running = false
        return
    end

    handleNavigationKey(key)
end

local function handleKeyUp(key)
    if key == keys.leftCtrl or key == keys.rightCtrl then
        state.ctrlDown = false
    elseif key == keys.leftShift or key == keys.rightShift then
        state.shiftDown = false
    end
end

local function handleTimer(timerId)
    if state.tabRevealTimer and timerId == state.tabRevealTimer then
        state.tabRevealTimer = nil
        state.tabNameReveal = nil
    end
end

local function handleChar(character)
    if activeTab().urlFocus then
        insertUrlText(character)
    end
end

local function handlePaste(text)
    if state.skipNextPaste then
        state.skipNextPaste = false
        return
    end
    if activeTab().urlFocus then
        insertUrlText(text)
        if text and text ~= "" then
            state.clipboard = text
        end
    end
end

local function bootstrap(initialUrls)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)

    if not initialUrls or #initialUrls == 0 then
        navigate("about:help", true, false, activeTab())
        return
    end

    for i, url in ipairs(initialUrls) do
        local tab = nil
        if i == 1 then
            tab = activeTab()
        else
            tab = newTab("about:blank")
        end
        navigate(url, true, true, tab)
    end
    activateTab(1)
    draw()
end

local function run(...)
    local initialUrls = { ... }
    bootstrap(initialUrls)
    while state.running do
        local event = { os.pullEvent() }
        local name = event[1]
        if state.skipNextPaste and name ~= "paste" and name ~= "key_up" then
            state.skipNextPaste = false
        end

        if name == "mouse_click" then
            handleMouseClick(event[2], event[3], event[4])
        elseif name == "mouse_drag" then
            handleMouseDrag(event[2], event[3], event[4])
        elseif name == "mouse_up" then
            handleMouseUp(event[2], event[3], event[4])
        elseif name == "mouse_scroll" then
            handleMouseScroll(event[2], event[3], event[4])
        elseif name == "key" then
            handleKeyDown(event[2])
        elseif name == "key_up" then
            handleKeyUp(event[2])
        elseif name == "char" then
            handleChar(event[2])
        elseif name == "paste" then
            handlePaste(event[2])
        elseif name == "timer" then
            handleTimer(event[2])
        elseif name == "term_resize" then
            renderDocument(activeTab())
        end

        draw()
    end

    term.setCursorBlink(false)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    print(APP_TITLE .. " closed")
end

return run
