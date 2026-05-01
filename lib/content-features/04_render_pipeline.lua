    local function renderNode(node, parentStyle, rules, writer, context, baseUrl, renderOptions)
        maybeYield()
        if node.type == "text" then
            writer:writeText(node.text or "", parentStyle, context.currentHref, parentStyle.whiteSpace == "pre")
            return
        end

        if node.type ~= "element" then
            return
        end

        local style = computeStyle(node, parentStyle, rules, renderOptions)
        if style.display == "none" then
            return
        end

        local tag = node.tag
        if tag == "br" then
            writer:newLine()
            return
        end

        if tag == "hr" then
            if context.componentsEnabled == false then
                return
            end
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
            if context.componentsEnabled == false then
                writer:writeText(alt, style, nil, false)
                return
            end
            writer:writeText("[" .. alt .. "]", style, nil, false)
            return
        end

        if tag == "input" and context.componentsEnabled ~= false then
            renderInputControl(node, style, writer, context)
            return
        end

        if tag == "select" and context.componentsEnabled ~= false then
            renderSelectControl(node, style, writer, context)
            return
        end

        if tag == "textarea" and context.componentsEnabled ~= false then
            renderTextAreaControl(node, style, writer, context)
            return
        end

        if tag == "button" and context.componentsEnabled ~= false then
            renderButtonControl(node, style, writer, context)
            return
        end

        local isBlock = style.display == "block"
        local previousIndent = nil
        if isBlock then
            previousIndent = writer:beginBlock(style)
        end

        local previousHref = context.currentHref
        if tag == "a" and context.linksEnabled ~= false and node.attrs and node.attrs.href then
            context.currentHref = resolveRelativeUrl(baseUrl, node.attrs.href)
        end

        local pushedList = false
        if tag == "ul" or tag == "ol" then
            table.insert(context.listStack, { kind = tag, index = 0 })
            pushedList = true
        end

        local pushedForm = false
        if tag == "form" and context.interactiveEnabled ~= false then
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
            renderNode(child, style, rules, writer, context, baseUrl, renderOptions)
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
        local renderOptions = resolveRenderOptions(baseUrl)
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
        if renderOptions.allowDocumentCss then
            addCss(defaults)
        end

        if renderOptions.allowDocumentCss then
            for _, css in ipairs(cssBlocks) do
                addCss(css)
            end

            if renderOptions.allowExternalCss then
                local maxExternalStylesheets = renderOptions.advancedUncapped and nil or 6
                local loaded = 0
                local seen = {}
                for _, href in ipairs(cssLinks) do
                    maybeYield()
                    if maxExternalStylesheets and loaded >= maxExternalStylesheets then
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
            end
        end

        local baseStyle = {
            display = "block",
            fg = renderOptions.defaultForeground,
            bg = nil,
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
        local htmlStyle = htmlNode and computeStyle(htmlNode, baseStyle, rules, renderOptions) or baseStyle
        local bodyStyle = bodyNode and computeStyle(bodyNode, htmlStyle, rules, renderOptions) or htmlStyle

        local pageBackground = bodyStyle.bg or htmlStyle.bg or renderOptions.defaultBackground
        return {
            root = root,
            rules = rules,
            baseUrl = baseUrl,
            title = pageTitle or "",
            source = htmlText,
            renderOptions = renderOptions,
            defaultForeground = ensureContrastingForeground(bodyStyle.fg or htmlStyle.fg or baseStyle.fg, pageBackground),
            defaultBackground = pageBackground,
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
        local renderOptions = document.renderOptions or resolveRenderOptions(document.baseUrl)
        local baseStyle = {
            display = "block",
            fg = document.defaultForeground or renderOptions.defaultForeground or colors.white,
            bg = nil,
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
            local bodyStyle = computeStyle(bodyNode, baseStyle, document.rules, renderOptions)
            baseStyle.fg = bodyStyle.fg or baseStyle.fg
            baseStyle.bg = bodyStyle.bg or baseStyle.bg
        end

        local writerOptions = {}
        if useWindow then
            writerOptions = {
                windowStartLine = startLine,
                windowEndLine = startLine + lineCount - 1,
            }
        end
        if renderOptions.monochromeText then
            writerOptions.monochromeForeground = document.defaultForeground or renderOptions.defaultForeground or colors.white
        end
        local pageBackground = document.defaultBackground or renderOptions.defaultBackground or colors.black
        local writer = createWriter(contentWidth, pageBackground, writerOptions)
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
            interactiveEnabled = renderOptions.interactiveEnabled ~= false,
            linksEnabled = renderOptions.linksEnabled ~= false,
            componentsEnabled = renderOptions.componentsEnabled ~= false,
        }
        local renderRoot = bodyNode or findFirstTag(document.root, "html") or document.root
        renderNode(renderRoot, baseStyle, document.rules, writer, context, document.baseUrl, renderOptions)

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
