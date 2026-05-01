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
    local getEngineLevel = deps.getEngineLevel
    local getDefaultBackgroundColor = deps.getDefaultBackgroundColor
    local getDefaultForegroundColor = deps.getDefaultForegroundColor or deps.getDefaultTextColor
    local YIELD_EVENT = "__cc_browser_content_yield"
    local YIELD_STEP_BUDGET = 1400
    local yieldSteps = 0

    local SUPPORTED_COLOR_NAMES = {
        "white",
        "orange",
        "magenta",
        "lightblue",
        "yellow",
        "lime",
        "pink",
        "gray",
        "lightgray",
        "cyan",
        "purple",
        "blue",
        "brown",
        "green",
        "red",
        "black",
    }
    local COLOR_NAME_TO_VALUE = {
        white = colors.white,
        orange = colors.orange,
        magenta = colors.magenta,
        lightblue = colors.lightBlue,
        yellow = colors.yellow,
        lime = colors.lime,
        pink = colors.pink,
        gray = colors.gray,
        lightgray = colors.lightGray,
        cyan = colors.cyan,
        purple = colors.purple,
        blue = colors.blue,
        brown = colors.brown,
        green = colors.green,
        red = colors.red,
        black = colors.black,
    }
    local COLOR_NAME_ALIASES = {
        white = "white",
        orange = "orange",
        magenta = "magenta",
        lightblue = "lightblue",
        light_blue = "lightblue",
        yellow = "yellow",
        lime = "lime",
        pink = "pink",
        gray = "gray",
        grey = "gray",
        lightgray = "lightgray",
        lightgrey = "lightgray",
        light_gray = "lightgray",
        light_grey = "lightgray",
        cyan = "cyan",
        purple = "purple",
        blue = "blue",
        brown = "brown",
        green = "green",
        red = "red",
        black = "black",
    }
    local COLOR_VALUE_TO_NAME = {}
    for name, colorValue in pairs(COLOR_NAME_TO_VALUE) do
        COLOR_VALUE_TO_NAME[colorValue] = name
    end

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

    local function normalizeEngineLevel(value)
        local lowered = trim(tostring(value or "")):lower()
        lowered = lowered:gsub("%-", "_")
        if lowered == "text" or lowered == "textonly" then
            lowered = "text_only"
        end
        if lowered == "lite" then
            lowered = "standard"
        end
        if lowered ~= "text_only" and lowered ~= "standard" and lowered ~= "advanced" then
            return "standard"
        end
        return lowered
    end

    local function parseConfiguredColorValue(rawColor, fallbackColor)
        local raw = trim(tostring(rawColor or "")):lower()
        if raw ~= "" then
            local compact = raw:gsub("%s+", ""):gsub("%-", "_")
            local alias = COLOR_NAME_ALIASES[compact]
            if alias and COLOR_NAME_TO_VALUE[alias] then
                return COLOR_NAME_TO_VALUE[alias]
            end
            local parsed = parseCssColor(raw, nil)
            if parsed ~= nil then
                return parsed
            end
        end
        return fallbackColor
    end

    local function normalizePaletteColorName(rawColor, fallbackName)
        local fallback = fallbackName or "white"
        local raw = trim(tostring(rawColor or "")):lower()
        if raw == "" then
            return fallback
        end
        local compact = raw:gsub("%s+", ""):gsub("%-", "_")
        local alias = COLOR_NAME_ALIASES[compact]
        if alias then
            return alias
        end
        local parsed = parseCssColor(raw, nil)
        if parsed and COLOR_VALUE_TO_NAME[parsed] then
            return COLOR_VALUE_TO_NAME[parsed]
        end
        return fallback
    end

    local function isAboutPageUrl(url)
        local lowered = trim(tostring(url or "")):lower()
        return lowered:sub(1, 6) == "about:"
    end

    local function resolveRenderOptions(baseUrl)
        local engineLevel = normalizeEngineLevel(type(getEngineLevel) == "function" and getEngineLevel() or "standard")
        if isAboutPageUrl(baseUrl) then
            engineLevel = "advanced"
        end
        local isTextOnly = engineLevel == "text_only"
        local isStandard = engineLevel == "standard"
        local isAdvanced = engineLevel == "advanced"
        local defaultBg = parseConfiguredColorValue(
            type(getDefaultBackgroundColor) == "function" and getDefaultBackgroundColor() or "black",
            colors.black
        )
        local defaultFg = parseConfiguredColorValue(
            type(getDefaultForegroundColor) == "function" and getDefaultForegroundColor() or "white",
            colors.white
        )
        defaultFg = ensureContrastingForeground(defaultFg, defaultBg)

        return {
            engineLevel = engineLevel,
            allowDocumentCss = isStandard or isAdvanced,
            allowExternalCss = isStandard or isAdvanced,
            cssColorOnly = isStandard,
            allowPresentationalColors = isStandard or isAdvanced,
            allowSemanticLinkColor = isStandard or isAdvanced,
            interactiveEnabled = not isTextOnly,
            linksEnabled = not isTextOnly,
            componentsEnabled = not isTextOnly,
            monochromeText = isTextOnly,
            advancedUncapped = isAdvanced,
            defaultBackground = defaultBg,
            defaultForeground = defaultFg,
        }
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

    local function applyTagDefaults(style, tag, renderOptions)
        if BLOCK_TAGS[tag] then
            style.display = "block"
        end

        if tag == "a" and (renderOptions == nil or renderOptions.allowSemanticLinkColor ~= false) then
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

    local function applyDeclaration(style, property, value, renderOptions)
        local prop = trim((property or ""):lower())
        local raw = trim(value or "")
        local lower = raw:lower()
        local colorOnly = renderOptions and renderOptions.cssColorOnly == true
        if colorOnly
            and prop ~= "color"
            and prop ~= "background-color"
            and prop ~= "background"
            and prop ~= "font-weight"
            and prop ~= "text-transform" then
            return
        end

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

    local function computeStyle(node, parentStyle, rules, renderOptions)
        local style = newComputedStyle(parentStyle)
        applyTagDefaults(style, node.tag, renderOptions)
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
                            applyDeclaration(style, prop, value, renderOptions)
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
            if node.attrs.style and (renderOptions == nil or renderOptions.allowDocumentCss ~= false) then
                local inlineStyle = parseDeclarations(node.attrs.style .. ";")
                for prop, value in pairs(inlineStyle) do
                    applyDeclaration(style, prop, value, renderOptions)
                end
            end
            if node.attrs.color and (renderOptions == nil or renderOptions.allowPresentationalColors ~= false) then
                style.fg = parseCssColor(node.attrs.color, style.fg)
            end
            if node.attrs.bgcolor and (renderOptions == nil or renderOptions.allowPresentationalColors ~= false) then
                style.bg = parseCssColor(node.attrs.bgcolor, style.bg)
            end
        end

        return style
    end

