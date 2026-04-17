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
        }

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

        return true
    end

    local function selectorMatchesNode(selector, node)
        local parts = selector.parts
        if #parts == 0 then
            return false
        end

        local current = node
        for i = #parts, 1, -1 do
            local part = parts[i]
            if i == #parts then
                if not matchesSimpleSelector(current, part) then
                    return false
                end
                current = current.parent
            else
                local matched = false
                while current do
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
        }
    end

    local function computeStyle(node, parentStyle, rules)
        local style = newComputedStyle(parentStyle)
        applyTagDefaults(style, node.tag)

        local appliedMeta = {}
        for _, rule in ipairs(rules) do
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
        }
    end

    local function createWriter(width, pageBackground)
        local writer = {
            width = math.max(1, width),
            pageBackground = pageBackground or colors.black,
            lines = { createEmptyLine() },
            x = 1,
            y = 1,
            indent = 0,
            pendingSpace = false,
        }

        function writer:getLine(index)
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
            end
        end

        function writer:newLine()
            self.y = self.y + 1
            self:getLine(self.y)
            self.x = self.indent + 1
            self.pendingSpace = false
        end

        function writer:putChar(ch, style, href)
            if self.x > self.width then
                self:newLine()
            end
            local line = self:getLine(self.y)
            line.chars[self.x] = ch
            line.fg[self.x] = style.fg or colors.white
            line.bg[self.x] = style.bg or self.pageBackground
            line.links[self.x] = href
            self.x = self.x + 1
        end

        function writer:writeSpace(style, href)
            if self:atLineStart() then
                return
            end
            local line = self:getLine(self.y)
            if line.chars[self.x - 1] == " " then
                return
            end
            self:putChar(" ", style, href)
        end

        function writer:writeWord(word, style, href)
            if word == "" then
                return
            end
            if #word <= self.width and (self.x + #word - 1 > self.width) and (not self:atLineStart()) then
                self:newLine()
            end
            for i = 1, #word do
                self:putChar(word:sub(i, i), style, href)
            end
        end

        function writer:writePreservedText(text, style, href)
            self.pendingSpace = false
            local transformed = transformText(text, style.textTransform)
            for i = 1, #transformed do
                local ch = transformed:sub(i, i)
                if ch == "\r" then
                    -- Ignore.
                elseif ch == "\n" then
                    self:newLine()
                elseif ch == "\t" then
                    local offset = (self.x - (self.indent + 1)) % 4
                    local spaces = 4 - offset
                    for _ = 1, spaces do
                        self:putChar(" ", style, href)
                    end
                else
                    self:putChar(ch, style, href)
                end
            end
        end

        function writer:writeCollapsedText(text, style, href)
            local i = 1
            local length = #text
            while i <= length do
                local ch = text:sub(i, i)
                if ch:match("%s") then
                    self.pendingSpace = true
                    i = i + 1
                else
                    local j = i
                    while j <= length and not text:sub(j, j):match("%s") do
                        j = j + 1
                    end
                    local word = text:sub(i, j - 1)
                    word = transformText(word, style.textTransform)
                    if self.pendingSpace then
                        self:writeSpace(style, href)
                    end
                    self.pendingSpace = false
                    self:writeWord(word, style, href)
                    i = j
                end
            end
        end

        function writer:writeText(text, style, href, preserveWhitespace)
            local decoded = decodeEntities(text or "")
            if decoded == "" then
                return
            end
            if preserveWhitespace then
                self:writePreservedText(decoded, style, href)
            else
                self:writeCollapsedText(decoded, style, href)
            end
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
            self.pendingSpace = false
            return previousIndent
        end

        function writer:endBlock(style, previousIndent)
            self.pendingSpace = false
            if not self:atLineStart() then
                self:newLine()
            end
            local bottom = style.marginBottom or 0
            for _ = 1, bottom do
                self:newLine()
            end
            self:setIndent(previousIndent or 0)
            self.x = self.indent + 1
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

    local function renderNode(node, parentStyle, rules, writer, context, baseUrl)
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
            renderNode(child, style, rules, writer, context, baseUrl)
        end

        if liIndent then
            writer:setIndent(liIndent)
        end

        if pushedList then
            table.remove(context.listStack)
        end

        context.currentHref = previousHref

        if isBlock then
            writer:endBlock(style, previousIndent)
        end
    end

    local function findFirstTag(node, tagName)
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

        return {
            root = root,
            rules = rules,
            baseUrl = baseUrl,
            title = pageTitle or "",
            source = htmlText,
        }
    end

    local function renderDocumentLines(document, width)
        if not document then
            return { createEmptyLine() }
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
        }

        local bodyNode = findFirstTag(document.root, "body")
        if bodyNode then
            local bodyStyle = computeStyle(bodyNode, baseStyle, document.rules)
            baseStyle.fg = bodyStyle.fg or baseStyle.fg
            baseStyle.bg = bodyStyle.bg or baseStyle.bg
        end

        local writer = createWriter(contentWidth, baseStyle.bg)
        local context = {
            currentHref = nil,
            listStack = {},
        }
        local renderRoot = bodyNode or findFirstTag(document.root, "html") or document.root
        renderNode(renderRoot, baseStyle, document.rules, writer, context, document.baseUrl)
        trimTrailingBlankLines(writer.lines)
        return writer.lines
    end

    return {
        createEmptyLine = createEmptyLine,
        buildDocument = buildDocument,
        renderDocumentLines = renderDocumentLines,
    }
end
