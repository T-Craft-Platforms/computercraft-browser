return function(deps)
    local core = deps.core
    local html = deps.html
    local network = deps.network

    local trim = core.trim
    local clamp = core.clamp
    local parseCssColor = core.parseCssColor
    local parseLength = core.parseLength
    local parseBoxShorthand = core.parseBoxShorthand
    local transformText = core.transformText
    local decodeEntities = core.decodeEntities
    local resolveRelativeUrl = core.resolveRelativeUrl
    local BLOCK_TAGS = core.BLOCK_TAGS
    local HEADING_TAGS = core.HEADING_TAGS

    local parseHTML = html.parseHTML
    local walkNode = html.walkNode
    local nodeTextContent = html.nodeTextContent

    local fetchTextResource = network.fetchTextResource
    local YIELD_EVENT = "__cc_browser_content_yield"
    local YIELD_STEP_BUDGET = 1400
    local yieldSteps = 0

    local COLOR_LUMA = {
        [colors.white] = 240,
        [colors.orange] = 180,
        [colors.magenta] = 164,
        [colors.lightBlue] = 188,
        [colors.yellow] = 210,
        [colors.lime] = 165,
        [colors.pink] = 200,
        [colors.gray] = 76,
        [colors.lightGray] = 153,
        [colors.cyan] = 136,
        [colors.purple] = 130,
        [colors.blue] = 90,
        [colors.brown] = 108,
        [colors.green] = 120,
        [colors.red] = 114,
        [colors.black] = 17,
    }

    local function cooperativeYield()
        if os and type(os.queueEvent) == "function" and type(os.pullEventRaw) == "function" then
            os.queueEvent(YIELD_EVENT)
            os.pullEventRaw(YIELD_EVENT)
            return
        end
        if sleep then
            sleep(0)
        end
    end

    local function maybeYield(stepCost)
        yieldSteps = yieldSteps + (stepCost or 1)
        if yieldSteps >= YIELD_STEP_BUDGET then
            yieldSteps = 0
            cooperativeYield()
        end
    end

    local function colorLuma(color)
        return COLOR_LUMA[color] or 128
    end

    local function ensureContrastingForeground(foreground, background)
        if not background then
            return foreground or colors.white
        end
        local fg = foreground or colors.white
        if fg == background then
            if colorLuma(background) >= 128 then
                return colors.black
            end
            return colors.white
        end
        if math.abs(colorLuma(fg) - colorLuma(background)) < 48 then
            if colorLuma(background) >= 128 then
                return colors.black
            end
            return colors.white
        end
        return fg
    end

    local function parseDeclarations(source)
        local declarations = {}
        local clean = source or ""
        for prop, value in clean:gmatch("([%w%-]+)%s*:%s*([^;]+)") do
            declarations[prop:lower()] = trim(value)
        end
        return declarations
    end

    local function parseCSS(cssText, startOrder)
        local rules = {}
        local order = startOrder or 0
        local stripped = (cssText or ""):gsub("/%*.-%*/", "")

        for selectorBlock, body in stripped:gmatch("([^{}]+){([^}]*)}") do
            local selectors = {}
            for selector in selectorBlock:gmatch("[^,]+") do
                local trimmed = trim(selector)
                if trimmed ~= "" then
                    table.insert(selectors, trimmed)
                end
            end

            if #selectors > 0 then
                local declarations = parseDeclarations(body)
                if next(declarations) then
                    order = order + 1
                    table.insert(rules, {
                        selectors = selectors,
                        declarations = declarations,
                        order = order,
                    })
                end
            end
        end

        return rules, order
    end

    local selectorCache = {}

    local function parseSimpleSelector(part)
        local sanitized = part:gsub(":%w[%w%-_]*", "")
        local parsed = {
            any = sanitized == "*",
            tag = nil,
            ids = {},
            classes = {},
            attrs = {},
            attrPresence = {},
        }

        for attrName, attrValue in sanitized:gmatch("%[([%w_:%-]+)%s*=%s*['\"]?([^%]'\"]+)['\"]?%]") do
            table.insert(parsed.attrs, {
                name = attrName:lower(),
                value = attrValue:lower(),
            })
        end
        for attrName in sanitized:gmatch("%[([%w_:%-]+)%s*%]") do
            table.insert(parsed.attrPresence, attrName:lower())
        end

        sanitized = sanitized:gsub("%[[^%]]+%]", "")
        parsed.tag = sanitized:match("^([%a][%w%-]*)")
        for id in sanitized:gmatch("#([%w%-_]+)") do
            table.insert(parsed.ids, id:lower())
        end
        for className in sanitized:gmatch("%.([%w%-_]+)") do
            table.insert(parsed.classes, className:lower())
        end

        local specificity = 0
        specificity = specificity + (#parsed.ids * 100)
        specificity = specificity + (#parsed.classes * 10)
        specificity = specificity + (#parsed.attrs * 10)
        specificity = specificity + (#parsed.attrPresence * 10)
        if parsed.tag and parsed.tag ~= "*" then
            specificity = specificity + 1
        end
        parsed.specificity = specificity

        return parsed
    end

    local function getParsedSelector(selector)
        if selectorCache[selector] then
            return selectorCache[selector]
        end

        local parsed = {
            parts = {},
            specificity = 0,
        }

        for part in selector:gmatch("%S+") do
            local simple = parseSimpleSelector(part)
            table.insert(parsed.parts, simple)
            parsed.specificity = parsed.specificity + simple.specificity
        end

        selectorCache[selector] = parsed
        return parsed
    end

    local function getNodeClassSet(node)
        if node._classSet then
            return node._classSet
        end

        local classes = {}
        local classAttr = ""
        if node.attrs and node.attrs.class then
            classAttr = node.attrs.class:lower()
        end
        for token in classAttr:gmatch("%S+") do
            classes[token] = true
        end
        node._classSet = classes
        return classes
    end

    local function matchesSimpleSelector(node, simple)
        if node.type ~= "element" then
            return false
        end

        if simple.tag and simple.tag ~= node.tag then
            return false
        end

        if #simple.ids > 0 then
            local nodeId = node.attrs and node.attrs.id and node.attrs.id:lower() or ""
            for _, wantedId in ipairs(simple.ids) do
                if nodeId ~= wantedId then
                    return false
                end
            end
        end

        if #simple.classes > 0 then
            local classSet = getNodeClassSet(node)
            for _, wantedClass in ipairs(simple.classes) do
                if not classSet[wantedClass] then
                    return false
                end
            end
        end

        if #simple.attrPresence > 0 then
            local attrs = node.attrs or {}
            for _, attrName in ipairs(simple.attrPresence) do
                if attrs[attrName] == nil then
                    return false
                end
            end
        end

        if #simple.attrs > 0 then
            local attrs = node.attrs or {}
            for _, wanted in ipairs(simple.attrs) do
                local nodeValue = attrs[wanted.name]
                if nodeValue == nil or tostring(nodeValue):lower() ~= wanted.value then
                    return false
                end
            end
        end

        return true
    end

    local function selectorMatchesNode(selector, node)
        local parts = selector.parts
        if #parts == 0 then
            return false
        end

        local current = node
        for i = #parts, 1, -1 do
            maybeYield()
            local part = parts[i]
            if i == #parts then
                if not matchesSimpleSelector(current, part) then
                    return false
                end
                current = current.parent
            else
                local matched = false
                while current do
                    maybeYield()
                    if matchesSimpleSelector(current, part) then
                        matched = true
                        current = current.parent
                        break
                    end
                    current = current.parent
                end
                if not matched then
                    return false
                end
            end
        end

        return true
    end

    local function applyTagDefaults(style, tag)
        if BLOCK_TAGS[tag] then
            style.display = "block"
        end

        if tag == "a" then
            style.fg = colors.lightBlue
        elseif tag == "strong" or tag == "b" then
            style.bold = true
        elseif tag == "pre" then
            style.display = "block"
            style.whiteSpace = "pre"
            style.marginTop = math.max(style.marginTop, 1)
            style.marginBottom = math.max(style.marginBottom, 1)
            style.paddingLeft = math.max(style.paddingLeft, 1)
        elseif tag == "code" then
            style.whiteSpace = "pre"
        elseif tag == "li" then
            style.marginLeft = math.max(style.marginLeft, 1)
        elseif tag == "hr" then
            style.display = "block"
            style.marginTop = math.max(style.marginTop, 1)
            style.marginBottom = math.max(style.marginBottom, 1)
        elseif HEADING_TAGS[tag] then
            style.display = "block"
            style.bold = true
            style.marginTop = math.max(style.marginTop, 1)
            style.marginBottom = math.max(style.marginBottom, 1)
        end

        if tag == "style" or tag == "script" or tag == "head" or tag == "meta" or tag == "link" or tag == "title" then
            style.display = "none"
        end
    end

    local function applyDeclaration(style, property, value)
        local prop = trim((property or ""):lower())
        local raw = trim(value or "")
        local lower = raw:lower()
        local function parseOverflowValue(candidate)
            if candidate == "visible" or candidate == "hidden" or candidate == "scroll" or candidate == "auto" then
                return candidate
            end
            return nil
        end

        if prop == "display" then
            if lower == "none" or lower == "block" or lower == "inline" then
                style.display = lower
            end
        elseif prop == "color" then
            style.fg = parseCssColor(raw, style.fg)
        elseif prop == "background-color" then
            style.bg = parseCssColor(raw, style.bg)
        elseif prop == "background" then
            local color = parseCssColor(raw, style.bg)
            if color ~= style.bg or lower == "transparent" then
                style.bg = color
            else
                for token in lower:gmatch("%S+") do
                    local tokenColor = parseCssColor(token, nil)
                    if tokenColor ~= nil or token == "transparent" then
                        style.bg = tokenColor
                        break
                    end
                end
            end
        elseif prop == "font-weight" then
            if lower == "bold" then
                style.bold = true
            elseif lower == "normal" then
                style.bold = false
            else
                local numeric = tonumber(lower)
                if numeric then
                    style.bold = numeric >= 600
                end
            end
        elseif prop == "white-space" then
            if lower == "pre" or lower == "pre-wrap" then
                style.whiteSpace = "pre"
            else
                style.whiteSpace = "normal"
            end
        elseif prop == "text-transform" then
            if lower == "uppercase" or lower == "lowercase" or lower == "capitalize" or lower == "none" then
                style.textTransform = lower
            end
        elseif prop == "margin-top" then
            style.marginTop = parseLength(raw)
        elseif prop == "margin-bottom" then
            style.marginBottom = parseLength(raw)
        elseif prop == "margin-left" then
            style.marginLeft = parseLength(raw)
        elseif prop == "padding-left" then
            style.paddingLeft = parseLength(raw)
        elseif prop == "padding-right" then
            style.paddingRight = parseLength(raw)
        elseif prop == "margin" then
            local box = parseBoxShorthand(raw)
            style.marginTop = box[1]
            style.marginBottom = box[3]
            style.marginLeft = box[4]
        elseif prop == "padding" then
            local box = parseBoxShorthand(raw)
            style.paddingLeft = box[4]
            style.paddingRight = box[2]
        elseif prop == "overflow" then
            local value = parseOverflowValue(lower)
            if value then
                style.overflowX = value
                style.overflowY = value
            end
        elseif prop == "overflow-x" then
            local value = parseOverflowValue(lower)
            if value then
                style.overflowX = value
            end
        elseif prop == "overflow-y" then
            local value = parseOverflowValue(lower)
            if value then
                style.overflowY = value
            end
        elseif prop == "position" then
            if lower == "static" or lower == "relative" or lower == "absolute" or lower == "fixed" or lower == "sticky" then
                style.position = lower
            end
        elseif prop == "top" then
            style.top = parseLength(raw)
        elseif prop == "right" then
            style.right = parseLength(raw)
        elseif prop == "left" then
            style.left = parseLength(raw)
        end
    end

    local function newComputedStyle(parentStyle)
        return {
            display = "inline",
            fg = parentStyle and parentStyle.fg or colors.white,
            bg = nil,
            whiteSpace = parentStyle and parentStyle.whiteSpace or "normal",
            bold = parentStyle and parentStyle.bold or false,
            textTransform = parentStyle and parentStyle.textTransform or "none",
            marginTop = 0,
            marginBottom = 0,
            marginLeft = 0,
            paddingLeft = 0,
            paddingRight = 0,
            overflowX = "visible",
            overflowY = "visible",
            position = "static",
            top = 0,
            right = 0,
            left = 0,
        }
    end

    local function computeStyle(node, parentStyle, rules)
        local style = newComputedStyle(parentStyle)
        applyTagDefaults(style, node.tag)
        local appliedMeta = {}
        for _, rule in ipairs(rules) do
            maybeYield()
            for _, selector in ipairs(rule.selectors) do
                local parsedSelector = getParsedSelector(selector)
                if selectorMatchesNode(parsedSelector, node) then
                    local specificity = parsedSelector.specificity
                    for prop, value in pairs(rule.declarations) do
                        local current = appliedMeta[prop]
                        if (not current) or (specificity > current.specificity) or
                            (specificity == current.specificity and rule.order >= current.order) then
                            applyDeclaration(style, prop, value)
                            appliedMeta[prop] = {
                                specificity = specificity,
                                order = rule.order,
                            }
                        end
                    end
                end
            end
        end

        if node.attrs then
            if node.attrs.style then
                local inlineStyle = parseDeclarations(node.attrs.style .. ";")
                for prop, value in pairs(inlineStyle) do
                    applyDeclaration(style, prop, value)
                end
            end
            if node.attrs.color then
                style.fg = parseCssColor(node.attrs.color, style.fg)
            end
            if node.attrs.bgcolor then
                style.bg = parseCssColor(node.attrs.bgcolor, style.bg)
            end
        end

        return style
    end

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

    local function renderInputControl(node, style, writer, context)
        local attrs = node.attrs or {}
        local inputType = trim((attrs.type or "text"):lower())
        if inputType == "" then
            inputType = "text"
        end

        local formId = resolveControlFormId(context, node)
        local key = makeControlKey(formId, node)
        local defaultValue = tostring(attrs.value or "")
        if (inputType == "checkbox" or inputType == "radio") and defaultValue == "" then
            defaultValue = "on"
        end
        local defaults = {
            value = defaultValue,
            checked = hasBooleanAttr(attrs, "checked"),
            cursor = #defaultValue + 1,
            selectedIndex = 1,
            selectedIndices = {},
        }

        local control = {
            key = key,
            formId = formId,
            nodeId = node._nodeId or 0,
            tag = "input",
            inputType = inputType,
            name = attrs.name or "",
            id = attrs.id or "",
            className = attrs.class or "",
            disabled = hasBooleanAttr(attrs, "disabled"),
            readonly = hasBooleanAttr(attrs, "readonly"),
            required = hasBooleanAttr(attrs, "required"),
            placeholder = attrs.placeholder or "",
            maxLength = parseInteger(attrs.maxlength, nil),
            size = parseInteger(attrs.size, nil),
            minValue = tonumber(attrs.min),
            maxValue = tonumber(attrs.max),
            stepValue = tonumber(attrs.step),
            formAction = attrs.formaction or "",
            formMethod = attrs.formmethod or "",
            formEnctype = attrs.formenctype or "",
            defaultValue = defaultValue,
            defaultChecked = defaults.checked,
            defaults = defaults,
            options = nil,
        }
        local stateEntry = registerControl(context, formId, control)

        if inputType == "hidden" then
            return true
        end

        local focused = context.focusControlKey == key
        local controlStyle = cloneControlStyle(style, focused, control.disabled)
        local isBlock = style.display == "block"
        local previousIndent = nil
        if isBlock then
            previousIndent = writer:beginBlock(style)
        end

        if inputType == "checkbox" then
            local marker = stateEntry.checked and "[x]" or "[ ]"
            writer:writeControlText(marker, controlStyle, key)
        elseif inputType == "radio" then
            local marker = stateEntry.checked and "(o)" or "( )"
            writer:writeControlText(marker, controlStyle, key)
        elseif inputType == "submit" or inputType == "reset" or inputType == "button" or inputType == "image" then
            local label = trim(attrs.value or "")
            if label == "" then
                if inputType == "submit" then
                    label = "Submit"
                elseif inputType == "reset" then
                    label = "Reset"
                elseif inputType == "image" then
                    label = "Image"
                else
                    label = "Button"
                end
            end
            writer:writeControlText("[ " .. label .. " ]", controlStyle, key)
        else
            local value = tostring(stateEntry.value or "")
            if control.maxLength and control.maxLength >= 0 and #value > control.maxLength then
                value = value:sub(1, control.maxLength)
                stateEntry.value = value
            end
            stateEntry.cursor = clamp(parseInteger(stateEntry.cursor, (#value + 1)), 1, #value + 1)

            local shown = value
            if inputType == "password" then
                shown = string.rep("*", #value)
            end
            local placeholder = tostring(attrs.placeholder or "")
            local width = clampControlInnerWidth(writer, control.size or 16)

            if shown == "" and placeholder ~= "" and not focused then
                local placeholderStyle = cloneControlStyle(style, false, control.disabled)
                placeholderStyle.fg = colors.gray
                local clippedPlaceholder = placeholder
                if #clippedPlaceholder > width then
                    clippedPlaceholder = clippedPlaceholder:sub(1, width)
                end
                writer:writeControlText("[" .. clippedPlaceholder .. "]", placeholderStyle, key)
            else
                local visible = shown
                local cursorDisplay = stateEntry.cursor
                if #visible > width then
                    local start = 1
                    if focused and cursorDisplay > width then
                        start = cursorDisplay - width + 1
                    elseif not focused then
                        start = #visible - width + 1
                    end
                    visible = visible:sub(start, start + width - 1)
                    cursorDisplay = clamp(cursorDisplay - start + 1, 1, #visible + 1)
                end
                if focused then
                    visible = withCursorMarker(visible, cursorDisplay)
                end
                writer:writeControlText("[" .. visible .. "]", controlStyle, key)
            end
        end

        if isBlock then
            writer:endBlock(style, previousIndent)
        end
        return true
    end

    local function collectSelectOptions(node)
        local options = {}
        local function walkOptions(optionNode)
            for _, child in ipairs(optionNode.children or {}) do
                if child.type == "element" then
                    if child.tag == "option" then
                        local attrs = child.attrs or {}
                        local label = trim(decodeEntities(nodeTextContent(child) or ""))
                        local value = tostring(attrs.value or label)
                        options[#options + 1] = {
                            label = label,
                            value = value,
                            selected = hasBooleanAttr(attrs, "selected"),
                            disabled = hasBooleanAttr(attrs, "disabled"),
                        }
                    else
                        walkOptions(child)
                    end
                end
            end
        end
        walkOptions(node)
        if #options == 0 then
            options[1] = { label = "", value = "", selected = true, disabled = false }
        end
        return options
    end

    local function renderSelectControl(node, style, writer, context)
        local attrs = node.attrs or {}
        local formId = resolveControlFormId(context, node)
        local key = makeControlKey(formId, node)
        local options = collectSelectOptions(node)
        local defaultSelectedIndex = 1
        for index, option in ipairs(options) do
            if option.selected then
                defaultSelectedIndex = index
                break
            end
        end

        local control = {
            key = key,
            formId = formId,
            nodeId = node._nodeId or 0,
            tag = "select",
            inputType = "select",
            name = attrs.name or "",
            id = attrs.id or "",
            className = attrs.class or "",
            disabled = hasBooleanAttr(attrs, "disabled"),
            readonly = false,
            required = hasBooleanAttr(attrs, "required"),
            multiple = hasBooleanAttr(attrs, "multiple"),
            size = parseInteger(attrs.size, nil),
            options = options,
            defaultSelectedIndex = defaultSelectedIndex,
            defaults = {
                selectedIndex = defaultSelectedIndex,
                selectedIndices = { defaultSelectedIndex },
            },
        }
        local stateEntry = registerControl(context, formId, control)
        stateEntry.selectedIndex = clamp(parseInteger(stateEntry.selectedIndex, defaultSelectedIndex), 1, #options)
        if type(stateEntry.selectedIndices) ~= "table" then
            stateEntry.selectedIndices = { stateEntry.selectedIndex }
        end

        local focused = context.focusControlKey == key
        local controlStyle = cloneControlStyle(style, focused, control.disabled)
        local selectedOption = options[stateEntry.selectedIndex] or options[1]
        local label = tostring(selectedOption and selectedOption.label or "")
        if label == "" then
            label = tostring(selectedOption and selectedOption.value or "")
        end
        local width = clampControlInnerWidth(writer, control.size or math.max(12, #label))
        if #label > width then
            label = label:sub(1, width)
        end

        local isBlock = style.display == "block"
        local previousIndent = nil
        if isBlock then
            previousIndent = writer:beginBlock(style)
        end
        writer:writeControlText("< " .. label .. " >", controlStyle, key)
        if isBlock then
            writer:endBlock(style, previousIndent)
        end
        return true
    end

    local function renderTextAreaControl(node, style, writer, context)
        local attrs = node.attrs or {}
        local formId = resolveControlFormId(context, node)
        local key = makeControlKey(formId, node)
        local defaultValue = decodeEntities(nodeTextContent(node) or "")
        local control = {
            key = key,
            formId = formId,
            nodeId = node._nodeId or 0,
            tag = "textarea",
            inputType = "textarea",
            name = attrs.name or "",
            id = attrs.id or "",
            className = attrs.class or "",
            disabled = hasBooleanAttr(attrs, "disabled"),
            readonly = hasBooleanAttr(attrs, "readonly"),
            required = hasBooleanAttr(attrs, "required"),
            maxLength = parseInteger(attrs.maxlength, nil),
            rows = parseInteger(attrs.rows, nil),
            cols = parseInteger(attrs.cols, nil),
            defaults = {
                value = defaultValue,
                cursor = #defaultValue + 1,
            },
            defaultValue = defaultValue,
        }
        local stateEntry = registerControl(context, formId, control)
        local value = tostring(stateEntry.value or "")
        if control.maxLength and control.maxLength >= 0 and #value > control.maxLength then
            value = value:sub(1, control.maxLength)
            stateEntry.value = value
        end
        stateEntry.cursor = clamp(parseInteger(stateEntry.cursor, (#value + 1)), 1, #value + 1)

        local display = value:gsub("\r", ""):gsub("\n", " ")
        local focused = context.focusControlKey == key
        if focused then
            display = withCursorMarker(display, stateEntry.cursor)
        end

        local width = clampControlInnerWidth(writer, control.cols or math.max(18, #display))
        if #display > width then
            display = display:sub(1, width)
        end

        local isBlock = style.display == "block"
        local previousIndent = nil
        if isBlock then
            previousIndent = writer:beginBlock(style)
        end
        writer:writeControlText("[[" .. display .. "]]", cloneControlStyle(style, focused, control.disabled), key)
        if isBlock then
            writer:endBlock(style, previousIndent)
        end
        return true
    end

    local function renderButtonControl(node, style, writer, context)
        local attrs = node.attrs or {}
        local formId = resolveControlFormId(context, node)
        local key = makeControlKey(formId, node)
        local buttonType = trim((attrs.type or "submit"):lower())
        if buttonType == "" then
            buttonType = "submit"
        end
        local label = trim(decodeEntities(nodeTextContent(node) or ""))
        if label == "" then
            label = "Button"
        end
        local value = tostring(attrs.value or label)
        local control = {
            key = key,
            formId = formId,
            nodeId = node._nodeId or 0,
            tag = "button",
            inputType = buttonType,
            buttonType = buttonType,
            name = attrs.name or "",
            id = attrs.id or "",
            className = attrs.class or "",
            disabled = hasBooleanAttr(attrs, "disabled"),
            readonly = false,
            required = false,
            value = value,
            formAction = attrs.formaction or "",
            formMethod = attrs.formmethod or "",
            formEnctype = attrs.formenctype or "",
            defaults = {
                value = value,
            },
            defaultValue = value,
        }
        registerControl(context, formId, control)

        local focused = context.focusControlKey == key
        local isBlock = style.display == "block"
        local previousIndent = nil
        if isBlock then
            previousIndent = writer:beginBlock(style)
        end
        writer:writeControlText("[ " .. label .. " ]", cloneControlStyle(style, focused, control.disabled), key)
        if isBlock then
            writer:endBlock(style, previousIndent)
        end
        return true
    end

    local function renderNode(node, parentStyle, rules, writer, context, baseUrl)
        maybeYield()
        if node.type == "text" then
            writer:writeText(node.text or "", parentStyle, context.currentHref, parentStyle.whiteSpace == "pre")
            return
        end

        if node.type ~= "element" then
            return
        end

        local style = computeStyle(node, parentStyle, rules)
        if style.display == "none" then
            return
        end

        local tag = node.tag
        if tag == "br" then
            writer:newLine()
            return
        end

        if tag == "hr" then
            local previousIndent = writer:beginBlock(style)
            for _ = writer.indent + 1, writer.width do
                writer:putChar("-", style, nil)
            end
            writer:endBlock(style, previousIndent)
            return
        end

        if tag == "img" then
            local alt = "image"
            if node.attrs then
                alt = node.attrs.alt or node.attrs.title or alt
            end
            writer:writeText("[" .. alt .. "]", style, nil, false)
            return
        end

        if tag == "input" then
            renderInputControl(node, style, writer, context)
            return
        end

        if tag == "select" then
            renderSelectControl(node, style, writer, context)
            return
        end

        if tag == "textarea" then
            renderTextAreaControl(node, style, writer, context)
            return
        end

        if tag == "button" then
            renderButtonControl(node, style, writer, context)
            return
        end

        local isBlock = style.display == "block"
        local previousIndent = nil
        if isBlock then
            previousIndent = writer:beginBlock(style)
        end

        local previousHref = context.currentHref
        if tag == "a" and node.attrs and node.attrs.href then
            context.currentHref = resolveRelativeUrl(baseUrl, node.attrs.href)
        end

        local pushedList = false
        if tag == "ul" or tag == "ol" then
            table.insert(context.listStack, { kind = tag, index = 0 })
            pushedList = true
        end

        local pushedForm = false
        if tag == "form" then
            local formId = registerForm(context, node, baseUrl)
            table.insert(context.formStack, formId)
            pushedForm = true
        end

        local liIndent = nil
        if tag == "li" then
            local list = context.listStack[#context.listStack]
            local marker = "*"
            if list then
                list.index = list.index + 1
                if list.kind == "ol" then
                    marker = tostring(list.index) .. "."
                end
            end
            writer:writeText(marker .. " ", style, nil, true)
            liIndent = writer.indent
            writer:setIndent(math.min(writer.width - 1, writer.indent + #marker + 1))
        end

        for _, child in ipairs(node.children or {}) do
            maybeYield()
            renderNode(child, style, rules, writer, context, baseUrl)
        end

        if liIndent then
            writer:setIndent(liIndent)
        end

        if pushedList then
            table.remove(context.listStack)
        end
        if pushedForm then
            table.remove(context.formStack)
        end

        context.currentHref = previousHref

        if isBlock then
            writer:endBlock(style, previousIndent)
        end
    end

    local function findFirstTag(node, tagName)
        maybeYield()
        if node.type == "element" and node.tag == tagName then
            return node
        end
        for _, child in ipairs(node.children or {}) do
            local found = findFirstTag(child, tagName)
            if found then
                return found
            end
        end
        return nil
    end

    local function collectCssAndTitle(root)
        local cssBlocks = {}
        local cssLinks = {}
        local pageTitle = nil

        walkNode(root, function(node)
            if node.type == "element" then
                if node.tag == "style" then
                    local css = nodeTextContent(node)
                    if trim(css) ~= "" then
                        table.insert(cssBlocks, css)
                    end
                elseif node.tag == "link" then
                    local rel = node.attrs and node.attrs.rel and node.attrs.rel:lower() or ""
                    local href = node.attrs and node.attrs.href or nil
                    if href and rel:find("stylesheet", 1, true) then
                        table.insert(cssLinks, href)
                    end
                elseif node.tag == "title" and not pageTitle then
                    pageTitle = trim(decodeEntities(nodeTextContent(node)))
                end
            end
        end)

        return cssBlocks, cssLinks, pageTitle
    end

    local function buildDocument(htmlText, baseUrl)
        local root = parseHTML(htmlText)
        local nextNodeId = 0
        walkNode(root, function(node)
            if node.type == "element" then
                nextNodeId = nextNodeId + 1
                node._nodeId = nextNodeId
            end
        end)
        local cssBlocks, cssLinks, pageTitle = collectCssAndTitle(root)

        local rules = {}
        local order = 0
        local function addCss(css)
            local parsedRules
            parsedRules, order = parseCSS(css, order)
            for _, rule in ipairs(parsedRules) do
                table.insert(rules, rule)
            end
        end

        local defaults = [[
html, body { display: block; }
p { display: block; margin-top: 1; margin-bottom: 1; }
ul, ol, li { display: block; }
h1, h2, h3, h4, h5, h6 { display: block; font-weight: bold; margin-top: 1; margin-bottom: 1; }
pre { display: block; white-space: pre; margin-top: 1; margin-bottom: 1; padding-left: 1; }
form { display: block; margin-top: 1; margin-bottom: 1; }
input, textarea, select, button, option { display: inline; }
a { color: lightblue; }
style, script, head, meta, link, title { display: none; }
]]
        addCss(defaults)

        for _, css in ipairs(cssBlocks) do
            addCss(css)
        end

        local maxExternalStylesheets = 6
        local loaded = 0
        local seen = {}
        for _, href in ipairs(cssLinks) do
            maybeYield()
            if loaded >= maxExternalStylesheets then
                break
            end
            local cssUrl = resolveRelativeUrl(baseUrl, href)
            if cssUrl and not seen[cssUrl] then
                seen[cssUrl] = true
                local cssBody, _, _, err = fetchTextResource(cssUrl, false)
                if cssBody and not err then
                    addCss(cssBody)
                    loaded = loaded + 1
                end
            end
        end

        local baseStyle = {
            display = "block",
            fg = colors.white,
            bg = colors.black,
            whiteSpace = "normal",
            bold = false,
            textTransform = "none",
            marginTop = 0,
            marginBottom = 0,
            marginLeft = 0,
            paddingLeft = 0,
            paddingRight = 0,
            overflowX = "visible",
            overflowY = "visible",
        }
        local htmlNode = findFirstTag(root, "html")
        local bodyNode = findFirstTag(root, "body")
        local htmlStyle = htmlNode and computeStyle(htmlNode, baseStyle, rules) or baseStyle
        local bodyStyle = bodyNode and computeStyle(bodyNode, htmlStyle, rules) or htmlStyle

        return {
            root = root,
            rules = rules,
            baseUrl = baseUrl,
            title = pageTitle or "",
            source = htmlText,
            pageOverflowX = bodyStyle.overflowX or htmlStyle.overflowX or "visible",
            pageOverflowY = bodyStyle.overflowY or htmlStyle.overflowY or "visible",
        }
    end

    local function renderDocumentInternal(document, width, formState, focusControlKey, windowStartLine, windowLineCount)
        local useWindow = windowStartLine ~= nil and windowLineCount ~= nil
        local startLine = math.max(1, parseInteger(windowStartLine, 1) or 1)
        local lineCount = math.max(1, parseInteger(windowLineCount, 1) or 1)

        if not document then
            local emptyLines = {}
            if (not useWindow) or startLine <= 1 then
                emptyLines[1] = createEmptyLine()
            end
            return emptyLines, {
                formsById = {},
                formOrder = {},
                formsByHtmlId = {},
                controlsByKey = {},
                controlOrder = {},
                formState = formState or {},
            }, 1
        end

        local contentWidth = math.max(1, width or 1)
        local baseStyle = {
            display = "block",
            fg = colors.white,
            bg = colors.black,
            whiteSpace = "normal",
            bold = false,
            textTransform = "none",
            marginTop = 0,
            marginBottom = 0,
            marginLeft = 0,
            paddingLeft = 0,
            paddingRight = 0,
            overflowX = "visible",
            overflowY = "visible",
        }

        local bodyNode = findFirstTag(document.root, "body")
        if bodyNode then
            local bodyStyle = computeStyle(bodyNode, baseStyle, document.rules)
            baseStyle.fg = bodyStyle.fg or baseStyle.fg
            baseStyle.bg = bodyStyle.bg or baseStyle.bg
        end

        local writerOptions = nil
        if useWindow then
            writerOptions = {
                windowStartLine = startLine,
                windowEndLine = startLine + lineCount - 1,
            }
        end
        local writer = createWriter(contentWidth, baseStyle.bg, writerOptions)
        local context = {
            currentHref = nil,
            listStack = {},
            formStack = {},
            formsById = {},
            formOrder = {},
            formsByHtmlId = {},
            controlsByKey = {},
            controlOrder = {},
            formState = formState or {},
            focusControlKey = focusControlKey,
        }
        local renderRoot = bodyNode or findFirstTag(document.root, "html") or document.root
        renderNode(renderRoot, baseStyle, document.rules, writer, context, document.baseUrl)

        local totalLines = writer:contentLineCount()
        if writer.storeAllLines then
            trimTrailingBlankLines(writer.lines)
            totalLines = math.max(1, #writer.lines)
        end

        return writer.lines, {
            formsById = context.formsById,
            formOrder = context.formOrder,
            formsByHtmlId = context.formsByHtmlId,
            controlsByKey = context.controlsByKey,
            controlOrder = context.controlOrder,
            formState = context.formState,
        }, totalLines
    end

    local function renderDocumentLines(document, width, formState, focusControlKey)
        local lines, meta = renderDocumentInternal(document, width, formState, focusControlKey, nil, nil)
        return lines, meta
    end

    local function renderDocumentWindowLines(document, width, startLine, lineCount, formState, focusControlKey)
        return renderDocumentInternal(document, width, formState, focusControlKey, startLine, lineCount)
    end

    return {
        createEmptyLine = createEmptyLine,
        buildDocument = buildDocument,
        renderDocumentLines = renderDocumentLines,
        renderDocumentWindowLines = renderDocumentWindowLines,
    }
end
