function openHelpTab()
    local existingIndex = findFirstTabByUrlPrefix("about:help")
    if existingIndex then
        activateTab(existingIndex)
        return
    end

    local tab = newTab("about:help")
    navigate("about:help", true, false, tab)
end

function openOrFocusFavoritesTab()
    local existingIndex = findFirstTabByUrlPrefix("about:favorites")
    if existingIndex then
        activateTab(existingIndex)
        return
    end

    local tab = newTab("about:favorites")
    navigate("about:favorites", true, false, tab)
end

function openOrFocusHistoryTab()
    local existingIndex = findFirstTabByUrlPrefix("about:history")
    if existingIndex then
        activateTab(existingIndex)
        return
    end

    local tab = newTab("about:history")
    navigate("about:history", true, false, tab)
end

function pageLineToPrintableText(line, width)
    local limit = math.max(1, tonumber(width) or 1)
    local highest = 0
    local chars = (line and line.chars) or {}
    for index, ch in pairs(chars) do
        if ch and ch ~= " " and index > highest and index <= limit then
            highest = index
        end
    end
    if highest <= 0 then
        return ""
    end
    local out = {}
    for x = 1, highest do
        out[x] = chars[x] or " "
    end
    return table.concat(out)
end

function printablePageLines(tab)
    local target = tab or activeTab()
    local terminalWidth = term and term.getSize and term.getSize() or 1
    local width = math.max(1, tonumber(target.viewportWidth) or tonumber(terminalWidth) or 1)
    local lines = target.pageLines or { createEmptyLine() }
    local totalLines = math.max(1, pageLineCount(target))

    local output = {}
    for index = 1, totalLines do
        output[#output + 1] = pageLineToPrintableText(lines[index], width)
    end
    while #output > 1 and output[#output] == "" do
        table.remove(output)
    end
    return output
end

function listPrinterNames()
    local names = {}
    if not peripheral or type(peripheral.getNames) ~= "function" or type(peripheral.getType) ~= "function" then
        return names
    end
    for _, name in ipairs(peripheral.getNames() or {}) do
        local typeName = tostring(peripheral.getType(name) or ""):lower()
        if typeName == "printer" then
            names[#names + 1] = tostring(name)
        end
    end
    table.sort(names)
    return names
end

function wrapPrintLine(line, width)
    local source = tostring(line or "")
    local chunks = {}
    local chunkWidth = math.max(1, tonumber(width) or 1)
    if source == "" then
        chunks[1] = ""
        return chunks
    end
    local startIndex = 1
    while startIndex <= #source do
        chunks[#chunks + 1] = source:sub(startIndex, startIndex + chunkWidth - 1)
        startIndex = startIndex + chunkWidth
    end
    return chunks
end

function printLinesToPeripheral(printerDevice, lines, pageTitle)
    return printing.printLinesToPeripheral(printerDevice, lines, pageTitle, wrapPrintLine)
end

function promptPrinterSelection(printerNames)
    if #printerNames == 0 then
        return nil
    end
    if #printerNames == 1 then
        return printerNames[1]
    end

    local choice = nil
    local buttons = {}
    local keyActions = {}
    local maxShown = math.min(#printerNames, 9)
    local digitKeyNames = {
        "one",
        "two",
        "three",
        "four",
        "five",
        "six",
        "seven",
        "eight",
        "nine",
    }
    for index = 1, maxShown do
        local id = "select_" .. tostring(index)
        local short = "[" .. tostring(index) .. "]"
        local label = short .. " " .. tostring(printerNames[index])
        buttons[#buttons + 1] = {
            id = id,
            label = label,
            shortLabel = short,
            background = colors.gray,
            foreground = colors.white,
        }
        local keyName = digitKeyNames[index]
        local keyConstant = keyName and keys and keys[keyName] or nil
        if keyConstant then
            keyActions[keyConstant] = id
        end
    end
    buttons[#buttons + 1] = {
        id = "cancel",
        label = "[Cancel]",
        shortLabel = "[X]",
        background = colors.red,
        foreground = colors.white,
    }
    if keys and keys.escape then
        keyActions[keys.escape] = "cancel"
    end

    local infoLines = {
        "Multiple printers detected.",
        "Choose where to print this page:",
    }
    for index = 1, maxShown do
        infoLines[#infoLines + 1] = ("%d) %s"):format(index, tostring(printerNames[index]))
    end
    if #printerNames > maxShown then
        infoLines[#infoLines + 1] = ("Showing first %d printers only."):format(maxShown)
    end

    openModal({
        id = "printer_select",
        title = "Select Printer",
        titleBackground = colors.blue,
        titleForeground = colors.white,
        lines = infoLines,
        buttons = buttons,
        keyActions = keyActions,
        autoClose = false,
        onButton = function(buttonId)
            choice = buttonId
            clearModal()
            return false
        end,
    })
    draw()

    while choice == nil and state.modal.open do
        local event = { os.pullEvent() }
        handleModalEvent(event)
        if state.running then
            draw()
        end
    end

    local selectedIndex = tonumber(tostring(choice or ""):match("^select_(%d+)$"))
    if selectedIndex and printerNames[selectedIndex] then
        return printerNames[selectedIndex]
    end
    return nil
end

function printCurrentPage(tab)
    local target = tab or activeTab()
    local printers = listPrinterNames()
    if #printers == 0 then
        target.status = "Print failed: no printer peripheral found"
        log(target.status, LogLevel.warn)
        return false
    end

    local selectedPrinter = promptPrinterSelection(printers)
    if not selectedPrinter then
        target.status = "Print canceled"
        log(target.status, LogLevel.info)
        return false
    end

    local printerDevice = peripheral.wrap(selectedPrinter)
    if not printerDevice then
        target.status = "Print failed: could not access printer '" .. tostring(selectedPrinter) .. "'"
        log(target.status, LogLevel.error)
        return false
    end

    local pageTitle = trim((target.document and target.document.title) or "")
    if pageTitle == "" then
        pageTitle = trim(target.currentUrl or "")
    end
    local lines = printablePageLines(target)
    local payload = {
        "Title: " .. pageTitle,
        "URL: " .. trim(target.currentUrl or ""),
    }
    if os and type(os.date) == "function" then
        local okDate, dateText = pcall(os.date, "%Y-%m-%d %H:%M:%S")
        if okDate and dateText then
            payload[#payload + 1] = "Printed: " .. tostring(dateText)
        end
    end
    payload[#payload + 1] = ""
    for _, line in ipairs(lines) do
        payload[#payload + 1] = line
    end

    local okPrint, printErr, printedPages = printLinesToPeripheral(printerDevice, payload, pageTitle)
    if not okPrint then
        local prefix = "Print failed: "
        if tonumber(printedPages) and printedPages > 0 then
            prefix = ("Print failed after %d pages: "):format(math.floor(printedPages))
        end
        target.status = prefix .. tostring(printErr or "unknown error")
        log(target.status, LogLevel.error)
        return false
    end

    local pageCount = math.max(1, math.floor(tonumber(printedPages) or 0))
    target.status = ("Printed %d pages on %s"):format(pageCount, tostring(selectedPrinter))
    log(target.status, LogLevel.info)
    showSnackbar(("Printed %d pages"):format(pageCount), 1200)
    return true
end

function suggestedDownloadPath(url, body, headers)
    local sourceUrl = trim(tostring(url or ""))
    local name = sourceUrl:gsub("[?#].*$", ""):match("([^/\\]+)$") or ""
    local contentType = trim(tostring(getHeader(headers, "Content-Type") or "")):lower()
    local function sanitizeFileName(rawName)
        local cleaned = trim(tostring(rawName or ""))
        cleaned = cleaned:gsub("[^%w%._%-]", "_")
        cleaned = cleaned:gsub("_+", "_")
        cleaned = cleaned:gsub("^%.*", "")
        cleaned = cleaned:gsub("%.*$", "")
        if cleaned == "" then
            cleaned = "download"
        end
        return cleaned
    end

    if name == "" then
        if contentType:find("html", 1, true) or looksLikeHtml(body or "", contentType) then
            name = "index.html"
        elseif contentType:find("lua", 1, true) then
            name = "download.lua"
        else
            name = "download.txt"
        end
    elseif not name:match("%.[%w]+$") then
        if contentType:find("html", 1, true) or looksLikeHtml(body or "", contentType) then
            name = name .. ".html"
        elseif contentType:find("lua", 1, true) then
            name = name .. ".lua"
        else
            name = name .. ".txt"
        end
    end
    name = sanitizeFileName(name)
    return fs.combine(currentDownloadsDir(), name)
end

function downloadCurrentPage(tab)
    local target = tab or activeTab()
    local currentUrl = trim(tostring(target.currentUrl or target.urlInput or ""))
    if currentUrl == "" then
        target.status = "Download failed: no active URL"
        log(target.status, LogLevel.warn)
        return false
    end

    local body, finalUrl, headers, err = fetchTextResource(currentUrl, false)
    if not body then
        target.status = "Download failed: " .. tostring(err or "unknown error")
        log(target.status, LogLevel.error)
        return false
    end

    local okStorage, storageErr = ensureStoragePaths()
    if not okStorage then
        target.status = "Download failed: " .. tostring(storageErr or "storage unavailable")
        log(target.status, LogLevel.error)
        return false
    end

    local preferredPath = suggestedDownloadPath(finalUrl or currentUrl, body, headers)
    local savePath = preferredPath
    if fs.exists(savePath) and fs.isDir(savePath) then
        savePath = fs.combine(currentDownloadsDir(), "download.txt")
    end

    local function splitName(path)
        local filename = fs.getName(path)
        local stem, ext = filename:match("^(.*)%.([%w]+)$")
        if not stem or stem == "" then
            stem = filename
            ext = nil
        end
        return stem, ext
    end

    if fs.exists(savePath) then
        local directory = fs.getDir(savePath)
        local stem, ext = splitName(savePath)
        local suffix = 1
        while fs.exists(savePath) do
            local candidate = stem .. "-" .. tostring(suffix)
            if ext and ext ~= "" then
                candidate = candidate .. "." .. ext
            end
            savePath = fs.combine(directory, candidate)
            suffix = suffix + 1
        end
    end

    local okWrite, writeErr = writeTextFile(savePath, body)
    if not okWrite then
        target.status = "Download failed: " .. tostring(writeErr or "could not write file")
        log(target.status, LogLevel.error)
        return false
    end

    target.status = ("Downloaded %d bytes to %s"):format(#tostring(body or ""), tostring(savePath))
    log(target.status, LogLevel.info)
    showSnackbar("Download complete", 1200)
    return true
end

function toggleCurrentPageFavorite()
    local tab = activeTab()
    local currentUrl = trim(tab.currentUrl or "")
    if not canFavoriteUrl(currentUrl) then
        return false, "Cannot favorite about pages"
    end
    if isFavoriteUrl(currentUrl) then
        return removeBrowserFavorite(currentUrl)
    end
    local title = trim((tab.document and tab.document.title) or "")
    return addBrowserFavorite(currentUrl, title)
end

function toggleFullscreen(forceExitSeamless)
    if state.fullscreen then
        if state.seamlessAppletFullscreen and not forceExitSeamless then
            activeTab().status = "Seamless fullscreen active (press Ctrl+K to exit)"
            return false
        end
        state.fullscreen = false
        state.seamlessAppletFullscreen = false
        state.menuOpen = false
        rerenderAllTabs()
        return true
    end

    state.menuOpen = false
    state.seamlessAppletFullscreen = seamlessFullscreenSettingEnabled()
    state.fullscreen = true
    state.menuOpen = false
    rerenderAllTabs()
    return true
end

function hitMenuPanel(x, y)
    local menu = state.ui.menu
    local panel = menu and menu.panel or nil
    if not panel then
        return false
    end
    return x >= panel.x1 and x <= panel.x2 and y >= panel.y1 and y <= panel.y2
end

function handleMenuClick(x, y)
    local menu = state.ui.menu
    if not menu then
        return false
    end

    if hitRegion(x, y, menu.settings) then
        state.menuOpen = false
        openOrFocusSettingsTab()
        return true
    end
    if hitRegion(x, y, menu.help) then
        state.menuOpen = false
        openHelpTab()
        return true
    end
    if hitRegion(x, y, menu.addFavorite) then
        if menu.addFavoriteEnabled then
            toggleCurrentPageFavorite()
        end
        return true
    end
    if hitRegion(x, y, menu.favorites) then
        state.menuOpen = false
        openOrFocusFavoritesTab()
        return true
    end
    if hitRegion(x, y, menu.history) then
        state.menuOpen = false
        openOrFocusHistoryTab()
        return true
    end
    if hitRegion(x, y, menu.download) then
        state.menuOpen = false
        downloadCurrentPage()
        return true
    end
    if hitRegion(x, y, menu.print) then
        state.menuOpen = false
        printCurrentPage()
        return true
    end
    if hitRegion(x, y, menu.fullscreen) then
        toggleFullscreen()
        return true
    end
    if hitRegion(x, y, menu.exit) then
        state.menuOpen = false
        state.running = false
        return true
    end
    if hitMenuPanel(x, y) then
        return true
    end

    return true
end

function urlEncode(value)
    local source = tostring(value or "")
    return (source:gsub("([^%w%-_%.~])", function(ch)
        return ("%%%02X"):format(string.byte(ch))
    end))
end

function encodeFormFields(fields)
    local parts = {}
    for _, field in ipairs(fields or {}) do
        local name = urlEncode(field.name or "")
        local value = urlEncode(field.value or "")
        parts[#parts + 1] = name .. "=" .. value
    end
    return table.concat(parts, "&")
end

function appendQuery(url, query)
    local base = tostring(url or "")
    local extra = tostring(query or "")
    if extra == "" then
        return base
    end

    local fragment = ""
    local hashAt = base:find("#", 1, true)
    if hashAt then
        fragment = base:sub(hashAt)
        base = base:sub(1, hashAt - 1)
    end

    local sep = base:find("?", 1, true) and "&" or "?"
    return base .. sep .. extra .. fragment
end

function formControl(tab, key)
    local target = tab or activeTab()
    local meta = target.formMeta or {}
    local controls = meta.controlsByKey or {}
    local resolvedKey = key
    local colorOptionIndex = nil
    local colorAction = nil
    local control = controls[resolvedKey]
    if not control then
        local rawKey = tostring(key or "")
        local baseKey, optionIndexText = rawKey:match("^(.-)::color:(%d+)$")
        local baseKeyAction, actionName = rawKey:match("^(.-)::color:(prev)$")
        if not baseKeyAction then
            baseKeyAction, actionName = rawKey:match("^(.-)::color:(open)$")
        end
        if not baseKeyAction then
            baseKeyAction, actionName = rawKey:match("^(.-)::color:(next)$")
        end
        if baseKey and baseKey ~= "" then
            local candidate = controls[baseKey]
            if candidate and candidate.tag == "input" and tostring(candidate.inputType or ""):lower() == "color" then
                resolvedKey = baseKey
                control = candidate
                colorOptionIndex = tonumber(optionIndexText)
            end
        elseif baseKeyAction and baseKeyAction ~= "" then
            local candidate = controls[baseKeyAction]
            if candidate and candidate.tag == "input" and tostring(candidate.inputType or ""):lower() == "color" then
                resolvedKey = baseKeyAction
                control = candidate
                colorAction = actionName
            end
        end
    end
    if not control then
        return nil, nil, nil, nil, nil
    end
    target.formState = target.formState or {}
    local stateEntry = target.formState[resolvedKey]
    if not stateEntry then
        stateEntry = {}
        target.formState[resolvedKey] = stateEntry
    end
    return control, stateEntry, resolvedKey, colorOptionIndex, colorAction
end

function isEditableFormControl(control)
    if not control or control.disabled or control.readonly then
        return false
    end
    if control.tag == "textarea" then
        return true
    end
    if control.tag ~= "input" then
        return false
    end
    local inputType = tostring(control.inputType or "text"):lower()
    if inputType == "hidden"
        or inputType == "checkbox"
        or inputType == "radio"
        or inputType == "submit"
        or inputType == "reset"
        or inputType == "button"
        or inputType == "image"
        or inputType == "color" then
        return false
    end
    return true
end

function setFocusedFormControl(tab, key)
    local target = tab or activeTab()
    local changed = target.focusedFormControl ~= key or target.urlFocus
    target.focusedFormControl = key
    target.urlFocus = false
    clearUrlSelection(target)
    if changed then
        bumpRenderRevision(target)
    end
end

local clampControlCursor = formControls.clampCursor
local insertIntoFormControl = formControls.insert
local removeFromFormControl = formControls.remove

copyControlDefaults = formControls.copyControlDefaults

function resetForm(tab, formId)
    local target = tab or activeTab()
    return formControls.resetForm(target, formId, bumpRenderRevision)
end

pushFormField = formControls.pushFormField
collectInputFormField = formControls.collectInputFormField
collectSelectFormField = formControls.collectSelectFormField
collectButtonFormField = formControls.collectButtonFormField

function collectFormFields(tab, formId, submitterKey)
    local target = tab or activeTab()
    return formControls.collectFormFields(target, formId, submitterKey)
end

function refreshCurrentDocumentWithoutNavigation(tab)
    local target = tab or activeTab()
    local currentUrl = trim(target.currentUrl or "")
    if currentUrl == "" then
        return false
    end
    state.highUsage.loadingFrame = true

    local previous = {
        scroll = target.scroll or 0,
        formState = target.formState or {},
        focusedControl = target.focusedFormControl,
        urlFocused = target.urlFocus and true or false,
        urlInput = target.urlInput or currentUrl,
        urlCursor = target.urlCursor,
        urlOffset = target.urlOffset,
        urlSelStart = target.urlSelStart,
        urlSelEnd = target.urlSelEnd,
    }
    previous.urlCursor = previous.urlCursor or (#previous.urlInput + 1)
    previous.urlOffset = previous.urlOffset or 0

    local loaded = {
        body = nil,
        finalUrl = nil,
        headers = nil,
    }

    loaded.body, loaded.finalUrl, loaded.headers, loaded.err = fetchTextResource(currentUrl, false)
    if not loaded.body then
        loaded.finalUrl = currentUrl
        loaded.body = makeErrorPage(loaded.finalUrl, loaded.err or "Unknown error")
        loaded.headers = { ["Content-Type"] = "text/html" }
    end

    local contentType = getHeader(loaded.headers, "Content-Type") or ""
    if not looksLikeHtml(loaded.body, contentType) then
        loaded.body = "<html><body><pre>" .. escapeHtml(loaded.body) .. "</pre></body></html>"
    end

    loaded.resolvedUrl = loaded.finalUrl or currentUrl
    target.document = buildDocument(loaded.body, loaded.resolvedUrl)
    target.currentUrl = loaded.resolvedUrl
    target.aboutUpdateIntervalMs = parseAboutUpdateIntervalMs(loaded.headers)
    target.settingsStickyStatus = parseSettingsStatusMessage(loaded.headers, loaded.resolvedUrl)
    target.status = target.document.title or target.status

    if previous.urlFocused then
        target.urlInput = previous.urlInput
        target.urlCursor = clamp(previous.urlCursor, 1, #target.urlInput + 1)
        target.urlOffset = math.max(0, tonumber(previous.urlOffset) or 0)
        target.urlFocus = true
        target.urlSelStart = previous.urlSelStart
        target.urlSelEnd = previous.urlSelEnd
    else
        target.urlInput = loaded.resolvedUrl
        target.urlCursor = #target.urlInput + 1
        target.urlOffset = 0
        target.urlFocus = false
        clearUrlSelection(target)
    end

    target.formState = previous.formState
    target.formMeta = nil
    target.focusedFormControl = previous.focusedControl
    target.renderRevision = 0
    target.lastRenderSignature = nil
    target.scroll = previous.scroll
    renderDocument(target)
    if scheduleAboutUpdateTimer then
        scheduleAboutUpdateTimer()
    end
    return true
end

function submitForm(tab, formId, submitterKey)
    local target = tab or activeTab()
    local ctx = {
        target = target,
        meta = target.formMeta or {},
    }
    ctx.forms = ctx.meta.formsById or {}
    ctx.controls = ctx.meta.controlsByKey or {}
    ctx.form = ctx.forms[formId]
    if not ctx.form then
        return false
    end

    ctx.submitter = submitterKey and ctx.controls[submitterKey] or nil
    ctx.method = ctx.submitter and trim(ctx.submitter.formMethod or "") or ""
    if ctx.method == "" then
        ctx.method = trim(ctx.form.method or "")
    end
    ctx.method = ctx.method:lower()
    if ctx.method ~= "post" then
        ctx.method = "get"
    end

    ctx.action = ctx.submitter and trim(ctx.submitter.formAction or "") or ""
    if ctx.action == "" then
        ctx.action = trim(ctx.form.action or "")
    end
    if ctx.action == "" then
        ctx.action = ctx.target.currentUrl or "about:blank"
    end
    ctx.action = core.resolveRelativeUrl(ctx.target.currentUrl or ctx.action, ctx.action)

    ctx.encoded = encodeFormFields(collectFormFields(ctx.target, formId, submitterKey))
    ctx.requestUrl = ctx.action
    ctx.requestOptions = {
        method = ctx.method:upper(),
    }

    if ctx.method == "post" then
        ctx.enctype = ctx.submitter and trim(ctx.submitter.formEnctype or "") or ""
        if ctx.enctype == "" then
            ctx.enctype = trim(ctx.form.enctype or "")
        end
        if ctx.enctype == "" then
            ctx.enctype = "application/x-www-form-urlencoded"
        end
        ctx.requestOptions.headers = {
            ["Content-Type"] = ctx.enctype,
        }
        ctx.requestOptions.body = ctx.encoded
    else
        ctx.requestUrl = appendQuery(ctx.action, ctx.encoded)
    end

    ctx.err = select(4, fetchTextResource(ctx.requestUrl, true, ctx.requestOptions))
    if ctx.err then
        ctx.target.status = "Form submit failed: " .. tostring(ctx.err)
        log(ctx.target.status .. " (" .. tostring(ctx.requestUrl) .. ")", LogLevel.warn)
        return false
    end

    ctx.target.status = "Form submitted"
    log(ctx.target.status .. " (" .. tostring(ctx.requestUrl) .. ")", LogLevel.info)
    local currentAboutUrl = trim(ctx.target.currentUrl or ""):lower()
    if startsWith(currentAboutUrl, "about:history") then
        navigate(ctx.requestUrl, false, false, ctx.target, ctx.requestOptions)
    elseif startsWith(currentAboutUrl, "about:") then
        refreshCurrentDocumentWithoutNavigation(ctx.target)
    end
    return true
end

function cycleSelect(tab, control, stateEntry, direction)
    local target = tab or activeTab()
    local options = control.options or {}
    if #options == 0 then
        return false
    end
    local nextIndex = tonumber(stateEntry.selectedIndex) or control.defaultSelectedIndex or 1
    nextIndex = nextIndex + direction
    if nextIndex < 1 then
        nextIndex = #options
    elseif nextIndex > #options then
        nextIndex = 1
    end
    stateEntry.selectedIndex = nextIndex
    stateEntry.selectedIndices = { nextIndex }
    bumpRenderRevision(target)
    return true
end

function cycleColorInput(tab, control, stateEntry, direction)
    local target = tab or activeTab()
    local options = control.colorOptions or {}
    if #options == 0 then
        return false
    end

    local currentIndex = tonumber(stateEntry.colorIndex)
    if not currentIndex then
        local currentValue = trim(tostring(stateEntry.value or "")):lower()
        for i, name in ipairs(options) do
            if name == currentValue then
                currentIndex = i
                break
            end
        end
    end
    currentIndex = clamp(math.floor(currentIndex or 1), 1, #options)
    local nextIndex = currentIndex + (direction or 1)
    if nextIndex < 1 then
        nextIndex = #options
    elseif nextIndex > #options then
        nextIndex = 1
    end

    stateEntry.colorIndex = nextIndex
    stateEntry.value = tostring(options[nextIndex] or options[1] or "white")
    bumpRenderRevision(target)
    return true
end

function setColorInputIndex(tab, control, stateEntry, requestedIndex)
    local target = tab or activeTab()
    local options = control.colorOptions or {}
    if #options == 0 then
        return false
    end
    local index = tonumber(requestedIndex)
    if not index then
        return false
    end
    index = clamp(math.floor(index), 1, #options)
    stateEntry.colorIndex = index
    stateEntry.value = tostring(options[index] or options[1] or "white")
    stateEntry.colorFlyoutOpen = true
    bumpRenderRevision(target)
    return true
end

function openColorInputFlyout(tab, stateEntry)
    local target = tab or activeTab()
    stateEntry.colorFlyoutOpen = true
    bumpRenderRevision(target)
    return true
end

function activateRadioGroup(target, control, key, stateEntry)
    local formId = control.formId
    local name = trim(tostring(control.name or ""))
    if not formId or name == "" then
        stateEntry.checked = true
        return
    end

    local formMeta = target.formMeta or {}
    local form = formMeta.formsById and formMeta.formsById[formId] or nil
    local controls = formMeta.controlsByKey or {}
    for _, candidateKey in ipairs(form and form.controlKeys or {}) do
        local candidate = controls[candidateKey]
        if candidate
            and candidate.tag == "input"
            and tostring(candidate.inputType or ""):lower() == "radio"
            and trim(tostring(candidate.name or "")) == name then
            local candidateState = target.formState[candidateKey] or {}
            candidateState.checked = candidateKey == key
            target.formState[candidateKey] = candidateState
        end
    end
end

function activateInputControl(target, control, stateEntry, key)
    local inputType = tostring(control.inputType or "text"):lower()
    if inputType == "checkbox" then
        stateEntry.checked = not not stateEntry.checked
        bumpRenderRevision(target)
        return true
    end
    if inputType == "radio" then
        activateRadioGroup(target, control, key, stateEntry)
        bumpRenderRevision(target)
        return true
    end
    if inputType == "submit" or inputType == "image" then
        if control.formId then
            return submitForm(target, control.formId, key)
        end
        return true
    end
    if inputType == "color" then
        return cycleColorInput(target, control, stateEntry, 1)
    end
    if inputType == "reset" then
        if control.formId then
            return resetForm(target, control.formId)
        end
        return true
    end

    stateEntry.cursor = #tostring(stateEntry.value or "") + 1
    bumpRenderRevision(target)
    return true
end

function activateButtonControl(target, control, key)
    local buttonType = tostring(control.buttonType or "submit"):lower()
    if buttonType == "reset" then
        if control.formId then
            return resetForm(target, control.formId)
        end
        return true
    end
    if buttonType == "submit" and control.formId then
        return submitForm(target, control.formId, key)
    end
    bumpRenderRevision(target)
    return true
end

function activateFormControl(tab, key)
    local target = tab or activeTab()
    local control, stateEntry, resolvedKey, colorOptionIndex, colorAction = formControl(target, key)
    if not control or control.disabled then
        return false
    end

    setFocusedFormControl(target, resolvedKey)
    if colorOptionIndex
        and control.tag == "input"
        and tostring(control.inputType or ""):lower() == "color" then
        return setColorInputIndex(target, control, stateEntry, colorOptionIndex)
    end
    if colorAction
        and control.tag == "input"
        and tostring(control.inputType or ""):lower() == "color" then
        if colorAction == "prev" then
            stateEntry.colorFlyoutOpen = true
            return cycleColorInput(target, control, stateEntry, -1)
        end
        if colorAction == "next" then
            stateEntry.colorFlyoutOpen = true
            return cycleColorInput(target, control, stateEntry, 1)
        end
        if colorAction == "open" then
            return openColorInputFlyout(target, stateEntry)
        end
    end

    if control.tag == "input" then
        return activateInputControl(target, control, stateEntry, resolvedKey)
    end

    if control.tag == "textarea" then
        stateEntry.cursor = #tostring(stateEntry.value or "") + 1
        bumpRenderRevision(target)
        return true
    end

    if control.tag == "select" then
        return cycleSelect(target, control, stateEntry, 1)
    end

    if control.tag == "button" then
        return activateButtonControl(target, control, resolvedKey)
    end

    return false
end

function moveFocusedFormControl(tab, direction)
    local target = tab or activeTab()
    local meta = target.formMeta or {}
    local order = meta.controlOrder or {}
    if #order == 0 then
        return false
    end

    local startIndex = 0
    for index, key in ipairs(order) do
        if key == target.focusedFormControl then
            startIndex = index
            break
        end
    end

    local size = #order
    for offset = 1, size do
        local index = ((startIndex - 1 + (offset * direction)) % size) + 1
        local key = order[index]
        local control = meta.controlsByKey and meta.controlsByKey[key] or nil
        if control and not control.disabled and tostring(control.inputType or ""):lower() ~= "hidden" then
            setFocusedFormControl(target, key)
            local stateEntry = target.formState[key] or {}
            if isEditableFormControl(control) then
                stateEntry.cursor = #tostring(stateEntry.value or "") + 1
                target.formState[key] = stateEntry
            end
            return true
        end
    end

    return false
end

function handleFocusedFormControlKey(tab, key)
    local target = tab or activeTab()
    if not target.focusedFormControl then
        return false
    end

    local control, stateEntry = formControl(target, target.focusedFormControl)
    if not control then
        target.focusedFormControl = nil
        return false
    end

    if key == keys.escape then
        target.focusedFormControl = nil
        return true
    end

    if key == keys.tab then
        local direction = state.shiftDown and -1 or 1
        return moveFocusedFormControl(target, direction)
    end

    if key == keys.enter then
        if control.tag == "textarea" and isEditableFormControl(control) then
            insertIntoFormControl(stateEntry, control, "\n")
            return true
        end
        if control.tag == "input" then
            local inputType = tostring(control.inputType or "text"):lower()
            if inputType == "color" then
                return cycleColorInput(target, control, stateEntry, 1)
            end
            if inputType == "reset" or inputType == "submit" or inputType == "image" then
                return activateFormControl(target, control.key)
            end
            if inputType == "button" then
                return true
            end
        elseif control.tag == "button" then
            local buttonType = tostring(control.buttonType or "submit"):lower()
            if buttonType == "reset" or buttonType == "submit" then
                return activateFormControl(target, control.key)
            end
            if buttonType == "button" then
                return true
            end
        end
        if control.formId then
            return submitForm(target, control.formId, control.key)
        end
        return true
    end

    if key == keys.space then
        if control.tag == "input" then
            local inputType = tostring(control.inputType or "text"):lower()
            if inputType == "color" then
                return cycleColorInput(target, control, stateEntry, 1)
            end
            if inputType == "checkbox" or inputType == "radio" or inputType == "submit" or inputType == "reset" or inputType == "button" then
                return activateFormControl(target, control.key)
            end
        elseif control.tag == "select" or control.tag == "button" then
            return activateFormControl(target, control.key)
        end
    end

    if control.tag == "input" then
        local inputType = tostring(control.inputType or "text"):lower()
        if inputType == "color" and (key == keys.left or key == keys.up or key == keys.right or key == keys.down) then
            local direction = (key == keys.left or key == keys.up) and -1 or 1
            return cycleColorInput(target, control, stateEntry, direction)
        end
        if (inputType == "number" or inputType == "range")
            and (key == keys.up or key == keys.down)
            and isEditableFormControl(control) then
            local value = tonumber(stateEntry.value or control.defaultValue or "0") or 0
            local step = tonumber(control.stepValue) or 1
            if step == 0 then
                step = 1
            end
            local direction = (key == keys.up) and 1 or -1
            local nextValue = value + (step * direction)
            if tonumber(control.minValue) then
                nextValue = math.max(nextValue, tonumber(control.minValue))
            end
            if tonumber(control.maxValue) then
                nextValue = math.min(nextValue, tonumber(control.maxValue))
            end
            stateEntry.value = tostring(nextValue)
            stateEntry.cursor = #stateEntry.value + 1
            return true
        end
    end

    if control.tag == "select" then
        if key == keys.left or key == keys.up then
            return cycleSelect(target, control, stateEntry, -1)
        elseif key == keys.right or key == keys.down then
            return cycleSelect(target, control, stateEntry, 1)
        end
    end

    if not isEditableFormControl(control) then
        return true
    end

    clampControlCursor(stateEntry)
    if key == keys.left then
        stateEntry.cursor = clamp(stateEntry.cursor - 1, 1, #tostring(stateEntry.value or "") + 1)
        return true
    elseif key == keys.right then
        stateEntry.cursor = clamp(stateEntry.cursor + 1, 1, #tostring(stateEntry.value or "") + 1)
        return true
    elseif key == keys.home then
        stateEntry.cursor = 1
        return true
    elseif key == keys["end"] then
        stateEntry.cursor = #tostring(stateEntry.value or "") + 1
        return true
    elseif key == keys.backspace then
        removeFromFormControl(stateEntry, true)
        return true
    elseif key == keys.delete then
        removeFromFormControl(stateEntry, false)
        return true
    end

    return true
end

function handleFocusedFormControlChar(tab, character)
    local target = tab or activeTab()
    if not target.focusedFormControl then
        return false
    end
    local control, stateEntry = formControl(target, target.focusedFormControl)
    if not control or not isEditableFormControl(control) then
        return false
    end
    insertIntoFormControl(stateEntry, control, character)
    return true
end

function handleFocusedFormControlPaste(tab, text)
    local target = tab or activeTab()
    if not target.focusedFormControl then
        return false
    end
    local control, stateEntry = formControl(target, target.focusedFormControl)
    if not control or not isEditableFormControl(control) then
        return false
    end
    insertIntoFormControl(stateEntry, control, text or "")
    return true
end

