    local function createEmptyLine()
        return {
            chars = {},
            fg = {},
            bg = {},
            links = {},
            controls = {},
        }
    end

    local function createWriter(width, pageBackground, options)
        local config = options or {}
        local rawWindowStart = tonumber(config.windowStartLine)
        if rawWindowStart then
            rawWindowStart = math.floor(rawWindowStart)
        end
        local windowStartLine = math.max(1, rawWindowStart or 1)
        local requestedWindowEnd = tonumber(config.windowEndLine)
        if requestedWindowEnd then
            requestedWindowEnd = math.floor(requestedWindowEnd)
        end
        local windowEndLine = nil
        if requestedWindowEnd and requestedWindowEnd >= windowStartLine then
            windowEndLine = requestedWindowEnd
        end

        local writer = {
            width = math.max(1, width),
            pageBackground = pageBackground or colors.black,
            monochromeForeground = config.monochromeForeground,
            lines = {},
            x = 1,
            y = 1,
            indent = 0,
            pendingSpace = false,
            pendingSpaceStyle = nil,
            pendingSpaceHref = nil,
            pendingSpaceControl = nil,
            currentLineLastChar = nil,
            maxNonBlankLine = 0,
            windowStartLine = windowStartLine,
            windowEndLine = windowEndLine,
            storeAllLines = windowEndLine == nil,
        }

        if writer.storeAllLines then
            writer.lines[1] = createEmptyLine()
        end

        function writer:isLineVisible(index)
            if self.storeAllLines then
                return true
            end
            if index < self.windowStartLine then
                return false
            end
            if self.windowEndLine and index > self.windowEndLine then
                return false
            end
            return true
        end

        function writer:getLine(index)
            if not self:isLineVisible(index) then
                return nil
            end
            local line = self.lines[index]
            if not line then
                line = createEmptyLine()
                self.lines[index] = line
            end
            return line
        end

        function writer:atLineStart()
            return self.x <= (self.indent + 1)
        end

        function writer:setIndent(value)
            local maxIndent = math.max(0, self.width - 1)
            self.indent = clamp(value, 0, maxIndent)
            if self.x < (self.indent + 1) then
                self.x = self.indent + 1
                self.currentLineLastChar = nil
            end
        end

        function writer:newLine()
            self.y = self.y + 1
            self:getLine(self.y)
            self.x = self.indent + 1
            self.currentLineLastChar = nil
            self:clearPendingSpace()
        end

        function writer:clearPendingSpace()
            self.pendingSpace = false
            self.pendingSpaceStyle = nil
            self.pendingSpaceHref = nil
            self.pendingSpaceControl = nil
        end

        function writer:setPendingSpace(style, href, controlKey)
            self.pendingSpace = true
            self.pendingSpaceStyle = style
            self.pendingSpaceHref = href
            self.pendingSpaceControl = controlKey
        end

        function writer:flushPendingSpace(fallbackStyle, fallbackHref, fallbackControlKey)
            if not self.pendingSpace then
                return
            end
            local style = self.pendingSpaceStyle or fallbackStyle
            local href = self.pendingSpaceHref
            local controlKey = self.pendingSpaceControl
            if href == nil then
                href = fallbackHref
            end
            if controlKey == nil then
                controlKey = fallbackControlKey
            end
            if style then
                self:writeSpace(style, href, controlKey)
            end
            self:clearPendingSpace()
        end

        function writer:putChar(ch, style, href, controlKey)
            if self.x > self.width then
                self:newLine()
            end
            local line = self:getLine(self.y)
            if line then
                local bg = style.bg or self.pageBackground
                local fg = ensureContrastingForeground(style.fg, bg)
                if self.monochromeForeground then
                    bg = self.pageBackground
                    fg = self.monochromeForeground
                end
                line.chars[self.x] = ch
                line.fg[self.x] = fg
                line.bg[self.x] = bg
                line.links[self.x] = href
                line.controls[self.x] = controlKey
            end
            if ch ~= " " then
                self.maxNonBlankLine = math.max(self.maxNonBlankLine, self.y)
            end
            self.currentLineLastChar = ch
            self.x = self.x + 1
        end

        function writer:writeSpace(style, href, controlKey)
            if self:atLineStart() then
                return
            end
            if self.currentLineLastChar == " " then
                return
            end
            self:putChar(" ", style, href, controlKey)
        end

        function writer:writeWord(word, style, href, controlKey)
            if word == "" then
                return
            end
            if #word <= self.width and (self.x + #word - 1 > self.width) and (not self:atLineStart()) then
                self:newLine()
            end
            for i = 1, #word do
                self:putChar(word:sub(i, i), style, href, controlKey)
            end
        end

        function writer:writePreservedText(text, style, href, controlKey)
            self:clearPendingSpace()
            local transformed = transformText(text, style.textTransform)
            for i = 1, #transformed do
                maybeYield()
                local ch = transformed:sub(i, i)
                if ch == "\r" then
                    -- Ignore.
                elseif ch == "\n" then
                    self:newLine()
                elseif ch == "\t" then
                    local offset = (self.x - (self.indent + 1)) % 4
                    local spaces = 4 - offset
                    for _ = 1, spaces do
                        self:putChar(" ", style, href, controlKey)
                    end
                else
                    self:putChar(ch, style, href, controlKey)
                end
            end
        end

        function writer:writeCollapsedText(text, style, href, controlKey)
            local i = 1
            local length = #text
            while i <= length do
                maybeYield()
                local ch = text:sub(i, i)
                if ch:match("%s") then
                    self:setPendingSpace(style, href, controlKey)
                    i = i + 1
                else
                    local j = i
                    while j <= length and not text:sub(j, j):match("%s") do
                        j = j + 1
                    end
                    local word = text:sub(i, j - 1)
                    word = transformText(word, style.textTransform)
                    if self.pendingSpace then
                        self:flushPendingSpace(style, href, controlKey)
                    end
                    self:writeWord(word, style, href, controlKey)
                    i = j
                end
            end
        end

        function writer:writeText(text, style, href, preserveWhitespace, controlKey)
            local decoded = decodeEntities(text or "")
            if decoded == "" then
                return
            end
            if preserveWhitespace then
                self:flushPendingSpace(style, href, controlKey)
                self:writePreservedText(decoded, style, href, controlKey)
            else
                self:writeCollapsedText(decoded, style, href, controlKey)
            end
        end

        function writer:writeControlText(text, style, controlKey)
            local raw = tostring(text or "")
            if raw == "" then
                return
            end
            self:flushPendingSpace(style, nil, controlKey)
            self:writePreservedText(raw, style, nil, controlKey)
        end

        function writer:beginBlock(style)
            local previousIndent = self.indent
            local indentDelta = (style.marginLeft or 0) + (style.paddingLeft or 0)

            if not self:atLineStart() then
                self:newLine()
            end

            local top = style.marginTop or 0
            for _ = 1, top do
                self:newLine()
            end

            self:setIndent(previousIndent + indentDelta)
            self.x = self.indent + 1
            self.currentLineLastChar = nil
            self:clearPendingSpace()
            return previousIndent
        end

        function writer:endBlock(style, previousIndent)
            self:clearPendingSpace()
            if not self:atLineStart() then
                self:newLine()
            end
            local bottom = style.marginBottom or 0
            for _ = 1, bottom do
                self:newLine()
            end
            self:setIndent(previousIndent or 0)
            self.x = self.indent + 1
            self.currentLineLastChar = nil
        end

        function writer:contentLineCount()
            return math.max(1, self.maxNonBlankLine)
        end

        return writer
    end

    local function isLineBlank(line)
        for _, ch in pairs(line.chars or {}) do
            if ch and ch ~= " " then
                return false
            end
        end
        return true
    end

    local function trimTrailingBlankLines(lines)
        while #lines > 1 and isLineBlank(lines[#lines]) do
            table.remove(lines)
        end
    end

    local TEXT_INPUT_TYPES = {
        text = true,
        password = true,
        search = true,
        url = true,
        email = true,
        tel = true,
        number = true,
        range = true,
        color = true,
        date = true,
        ["datetime-local"] = true,
        month = true,
        week = true,
        time = true,
        file = true,
    }

    local function hasBooleanAttr(attrs, key)
        if not attrs then
            return false
        end
        local value = attrs[key]
        if value == nil then
            return false
        end
        local lowered = tostring(value):lower()
        return lowered ~= "false" and lowered ~= "0" and lowered ~= "off"
    end

    local function parseInteger(value, fallback)
        local number = tonumber(value)
        if not number then
            return fallback
        end
        return math.floor(number)
    end

    local function cloneControlStyle(baseStyle, focused, disabled)
        local cloned = {
            fg = baseStyle.fg,
            bg = baseStyle.bg,
            whiteSpace = "pre",
            bold = baseStyle.bold,
            textTransform = "none",
        }
        if disabled then
            cloned.fg = colors.gray
        end
        if focused then
            cloned.fg = colors.white
            cloned.bg = colors.blue
        end
        return cloned
    end

    local function copyList(values)
        local copied = {}
        for i, value in ipairs(values or {}) do
            copied[i] = value
        end
        return copied
    end

    local function registerForm(context, node, baseUrl)
        local attrs = node.attrs or {}
        local formId = "form:" .. tostring(node._nodeId or 0)
        local actionRaw = trim(attrs.action or "")
        local action = actionRaw ~= "" and resolveRelativeUrl(baseUrl, actionRaw) or baseUrl
        local method = trim((attrs.method or "get"):lower())
        if method == "" then
            method = "get"
        end
        local enctype = trim((attrs.enctype or "application/x-www-form-urlencoded"):lower())
        if enctype == "" then
            enctype = "application/x-www-form-urlencoded"
        end

        local form = context.formsById[formId]
        if not form then
            form = {
                id = formId,
                nodeId = node._nodeId or 0,
                action = action,
                method = method,
                enctype = enctype,
                target = attrs.target or "",
                controlKeys = {},
                htmlId = attrs.id or "",
                name = attrs.name or "",
            }
            context.formsById[formId] = form
            context.formOrder[#context.formOrder + 1] = formId
        else
            form.action = action
            form.method = method
            form.enctype = enctype
            form.target = attrs.target or ""
            form.htmlId = attrs.id or ""
            form.name = attrs.name or ""
            form.controlKeys = {}
        end

        local htmlId = trim(attrs.id or "")
        if htmlId ~= "" then
            context.formsByHtmlId[htmlId:lower()] = formId
        end

        return formId
    end

    local function resolveControlFormId(context, node)
        local attrs = node.attrs or {}
        local explicitForm = trim(attrs.form or "")
        if explicitForm ~= "" then
            local mapped = context.formsByHtmlId[explicitForm:lower()]
            if mapped then
                return mapped
            end
        end
        return context.formStack[#context.formStack]
    end

    local function makeControlKey(formId, node)
        local parent = formId or "form:none"
        return parent .. "|node:" .. tostring(node._nodeId or 0)
    end

    local function ensureControlState(context, control)
        local key = control.key
        local state = context.formState[key]
        if not state then
            state = {}
        end
        for defaultKey, defaultValue in pairs(control.defaults or {}) do
            if state[defaultKey] == nil then
                if type(defaultValue) == "table" then
                    state[defaultKey] = copyList(defaultValue)
                else
                    state[defaultKey] = defaultValue
                end
            end
        end
        context.formState[key] = state
        return state
    end

    local function registerControl(context, formId, control)
        local key = control.key
        context.controlsByKey[key] = control
        context.controlOrder[#context.controlOrder + 1] = key
        if formId then
            local form = context.formsById[formId]
            if form then
                form.controlKeys[#form.controlKeys + 1] = key
            end
        end
        return ensureControlState(context, control)
    end

    local function clampControlInnerWidth(writer, wanted)
        local available = math.max(1, writer.width - writer.indent - 2)
        return clamp(wanted, 1, available)
    end

    local function withCursorMarker(text, cursor)
        local source = tostring(text or "")
        local cursorPos = clamp(parseInteger(cursor, (#source + 1)), 1, #source + 1)
        return source:sub(1, cursorPos - 1) .. "|" .. source:sub(cursorPos), cursorPos
    end

