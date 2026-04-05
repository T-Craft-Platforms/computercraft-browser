-- CC Browser main application
-- Sections are filled incrementally to avoid command length limits.

local APP_TITLE = "CC Browser"

-- SECTION: constants

local VOID_TAGS = {
    area = true,
    base = true,
    br = true,
    col = true,
    embed = true,
    hr = true,
    img = true,
    input = true,
    link = true,
    meta = true,
    param = true,
    source = true,
    track = true,
    wbr = true,
}

local RAW_TEXT_TAGS = {
    script = true,
    style = true,
    title = true,
}

local BLOCK_TAGS = {
    article = true,
    aside = true,
    blockquote = true,
    body = true,
    div = true,
    dl = true,
    fieldset = true,
    figcaption = true,
    figure = true,
    footer = true,
    form = true,
    h1 = true,
    h2 = true,
    h3 = true,
    h4 = true,
    h5 = true,
    h6 = true,
    header = true,
    html = true,
    li = true,
    main = true,
    nav = true,
    ol = true,
    p = true,
    pre = true,
    section = true,
    table = true,
    tbody = true,
    td = true,
    th = true,
    thead = true,
    tr = true,
    ul = true,
}

local HEADING_TAGS = {
    h1 = true,
    h2 = true,
    h3 = true,
    h4 = true,
    h5 = true,
    h6 = true,
}

local CSS_COLOR_NAMES = {
    aqua = colors.cyan,
    black = colors.black,
    blue = colors.blue,
    brown = colors.brown,
    cyan = colors.cyan,
    fuchsia = colors.magenta,
    gray = colors.gray,
    grey = colors.gray,
    green = colors.green,
    lightblue = colors.lightBlue,
    lightgray = colors.lightGray,
    lightgrey = colors.lightGray,
    lime = colors.lime,
    magenta = colors.magenta,
    maroon = colors.red,
    navy = colors.blue,
    olive = colors.brown,
    orange = colors.orange,
    pink = colors.pink,
    purple = colors.purple,
    red = colors.red,
    silver = colors.lightGray,
    teal = colors.cyan,
    white = colors.white,
    yellow = colors.yellow,
}

local PALETTE = {
    { value = colors.white, r = 240, g = 240, b = 240 },
    { value = colors.orange, r = 242, g = 178, b = 51 },
    { value = colors.magenta, r = 229, g = 127, b = 216 },
    { value = colors.lightBlue, r = 153, g = 178, b = 242 },
    { value = colors.yellow, r = 222, g = 222, b = 108 },
    { value = colors.lime, r = 127, g = 204, b = 25 },
    { value = colors.pink, r = 242, g = 178, b = 204 },
    { value = colors.gray, r = 76, g = 76, b = 76 },
    { value = colors.lightGray, r = 153, g = 153, b = 153 },
    { value = colors.cyan, r = 76, g = 153, b = 178 },
    { value = colors.purple, r = 178, g = 102, b = 229 },
    { value = colors.blue, r = 51, g = 102, b = 204 },
    { value = colors.brown, r = 127, g = 102, b = 76 },
    { value = colors.green, r = 87, g = 166, b = 78 },
    { value = colors.red, r = 204, g = 76, b = 76 },
    { value = colors.black, r = 17, g = 17, b = 17 },
}

local ENTITY_MAP = {
    amp = "&",
    apos = "'",
    gt = ">",
    lt = "<",
    nbsp = " ",
    quot = "\"",
}

-- SECTION: utilities

local function clamp(value, minValue, maxValue)
    if value < minValue then
        return minValue
    end
    if value > maxValue then
        return maxValue
    end
    return value
end

local function trim(value)
    if value == nil then
        return ""
    end
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function startsWith(value, prefix)
    return value:sub(1, #prefix) == prefix
end

local function toAsciiChar(code)
    if code == 9 then
        return "\t"
    end
    if code == 10 then
        return "\n"
    end
    if code >= 32 and code <= 126 then
        return string.char(code)
    end
    return "?"
end

local function decodeEntities(value)
    if value == nil or value == "" then
        return ""
    end

    local decoded = value
    decoded = decoded:gsub("&#x([%x]+);", function(hex)
        local code = tonumber(hex, 16)
        if not code then
            return "?"
        end
        return toAsciiChar(code)
    end)
    decoded = decoded:gsub("&#([%d]+);", function(decimal)
        local code = tonumber(decimal, 10)
        if not code then
            return "?"
        end
        return toAsciiChar(code)
    end)
    decoded = decoded:gsub("&([%a]+);", function(name)
        return ENTITY_MAP[name] or ("&" .. name .. ";")
    end)
    return decoded
end

local function splitByWhitespace(value)
    local parts = {}
    for token in (value or ""):gmatch("%S+") do
        table.insert(parts, token)
    end
    return parts
end

local function escapeHtml(value)
    local escaped = value or ""
    escaped = escaped:gsub("&", "&amp;")
    escaped = escaped:gsub("<", "&lt;")
    escaped = escaped:gsub(">", "&gt;")
    escaped = escaped:gsub("\"", "&quot;")
    return escaped
end

local function nearestPaletteColor(red, green, blue)
    local best = colors.white
    local distance = math.huge

    for _, item in ipairs(PALETTE) do
        local dr = red - item.r
        local dg = green - item.g
        local db = blue - item.b
        local score = (dr * dr) + (dg * dg) + (db * db)
        if score < distance then
            distance = score
            best = item.value
        end
    end

    return best
end

local function parseRgbChannel(value)
    local part = trim(value or ""):lower()
    if part:sub(-1) == "%" then
        local percentage = tonumber(part:sub(1, -2))
        if not percentage then
            return nil
        end
        return clamp(math.floor((percentage / 100) * 255 + 0.5), 0, 255)
    end
    local number = tonumber(part)
    if not number then
        return nil
    end
    return clamp(math.floor(number + 0.5), 0, 255)
end

local function parseCssColor(value, fallback)
    local raw = trim((value or ""):lower())
    if raw == "" or raw == "inherit" then
        return fallback
    end
    if raw == "transparent" then
        return nil
    end

    local named = CSS_COLOR_NAMES[raw]
    if named then
        return named
    end

    local shortHex = raw:match("^#([%x][%x][%x])$")
    if shortHex then
        local r = tonumber(shortHex:sub(1, 1) .. shortHex:sub(1, 1), 16)
        local g = tonumber(shortHex:sub(2, 2) .. shortHex:sub(2, 2), 16)
        local b = tonumber(shortHex:sub(3, 3) .. shortHex:sub(3, 3), 16)
        return nearestPaletteColor(r, g, b)
    end

    local fullHex = raw:match("^#([%x][%x][%x][%x][%x][%x])$")
    if fullHex then
        local r = tonumber(fullHex:sub(1, 2), 16)
        local g = tonumber(fullHex:sub(3, 4), 16)
        local b = tonumber(fullHex:sub(5, 6), 16)
        return nearestPaletteColor(r, g, b)
    end

    local rPart, gPart, bPart = raw:match("^rgb%(([^,]+),([^,]+),([^%)]+)%)$")
    if rPart and gPart and bPart then
        local r = parseRgbChannel(rPart)
        local g = parseRgbChannel(gPart)
        local b = parseRgbChannel(bPart)
        if r and g and b then
            return nearestPaletteColor(r, g, b)
        end
    end

    return fallback
end

local function parseLength(value)
    local raw = trim((value or ""):lower())
    if raw == "" or raw == "auto" then
        return 0
    end

    local number, unit = raw:match("^([%-]?[%d%.]+)([%a%%]*)$")
    if not number then
        return 0
    end

    local n = tonumber(number)
    if not n or n <= 0 then
        return 0
    end

    if unit == "px" then
        n = n / 8
    elseif unit == "%" then
        n = n / 25
    end

    return clamp(math.floor(n + 0.5), 0, 12)
end

local function parseBoxShorthand(value)
    local tokens = splitByWhitespace(value)
    local out = { 0, 0, 0, 0 }
    if #tokens == 1 then
        local v = parseLength(tokens[1])
        out[1], out[2], out[3], out[4] = v, v, v, v
    elseif #tokens == 2 then
        local v1 = parseLength(tokens[1])
        local v2 = parseLength(tokens[2])
        out[1], out[2], out[3], out[4] = v1, v2, v1, v2
    elseif #tokens == 3 then
        local v1 = parseLength(tokens[1])
        local v2 = parseLength(tokens[2])
        local v3 = parseLength(tokens[3])
        out[1], out[2], out[3], out[4] = v1, v2, v3, v2
    elseif #tokens >= 4 then
        out[1] = parseLength(tokens[1])
        out[2] = parseLength(tokens[2])
        out[3] = parseLength(tokens[3])
        out[4] = parseLength(tokens[4])
    end
    return out
end

local function transformText(value, mode)
    if mode == "uppercase" then
        return value:upper()
    end
    if mode == "lowercase" then
        return value:lower()
    end
    if mode == "capitalize" then
        return (value:gsub("(%a)([%w_]*)", function(first, rest)
            return first:upper() .. rest:lower()
        end))
    end
    return value
end

local function normalizeUrlPath(path)
    local isAbsolute = startsWith(path, "/")
    local segments = {}

    for part in path:gmatch("[^/]+") do
        if part == "." or part == "" then
            -- Ignore.
        elseif part == ".." then
            if #segments > 0 then
                table.remove(segments)
            end
        else
            table.insert(segments, part)
        end
    end

    local output = table.concat(segments, "/")
    if isAbsolute then
        output = "/" .. output
    end
    if output == "" then
        return isAbsolute and "/" or ""
    end
    return output
end

local function stripFragment(url)
    return (url or ""):gsub("#.*$", "")
end

local function stripQueryAndFragment(url)
    return (url or ""):gsub("[?#].*$", "")
end

local function parseUrl(url)
    local scheme, rest = (url or ""):match("^([%a][%w+%-%.]*):(.*)$")
    if not scheme then
        return nil
    end
    scheme = scheme:lower()

    if startsWith(rest, "//") then
        local authority, pathAndMore = rest:match("^//([^/?#]*)(.*)$")
        if not authority then
            return nil
        end
        local path, suffix = (pathAndMore or ""):match("^([^?#]*)(.*)$")
        if path == nil or path == "" then
            path = "/"
        end
        return {
            scheme = scheme,
            authority = authority,
            path = path,
            suffix = suffix or "",
        }
    end

    return {
        scheme = scheme,
        path = rest,
        suffix = "",
    }
end

local function resolveRelativeUrl(baseUrl, href)
    local target = trim(href or "")
    if target == "" then
        return baseUrl
    end

    if target:match("^[%a][%w+%-%.]*:") then
        return target
    end

    if startsWith(target, "#") then
        return stripFragment(baseUrl) .. target
    end

    local parsedBase = parseUrl(baseUrl)
    if not parsedBase or not parsedBase.authority then
        return target
    end

    if startsWith(target, "//") then
        return parsedBase.scheme .. ":" .. target
    end

    if startsWith(target, "?") then
        return stripQueryAndFragment(baseUrl) .. target
    end

    local pathPart, suffix = target:match("^([^?#]*)(.*)$")
    local resolvedPath

    if startsWith(pathPart, "/") then
        resolvedPath = normalizeUrlPath(pathPart)
    else
        local basePath = parsedBase.path or "/"
        basePath = basePath:gsub("[?#].*$", "")
        local baseDir = basePath:match("^(.*)/") or ""
        if baseDir == "" then
            baseDir = "/"
        end
        resolvedPath = normalizeUrlPath(baseDir .. "/" .. pathPart)
    end

    if resolvedPath == "" then
        resolvedPath = "/"
    end

    return parsedBase.scheme .. "://" .. parsedBase.authority .. resolvedPath .. (suffix or "")
end

local function decodeUrlPath(path)
    local decoded = (path or ""):gsub("%%([%x][%x])", function(hex)
        return string.char(tonumber(hex, 16))
    end)
    return decoded
end

local function normalizeInputUrl(input)
    local value = trim(input or "")
    if value == "" then
        return "about:blank", false
    end
    if value:match("^[%a][%w+%-%.]*:") then
        return value, false
    end
    if startsWith(value, "/") or fs.exists(value) then
        return "file://" .. value, false
    end
    return "https://" .. value, true
end

local function getHeader(headers, key)
    if type(headers) ~= "table" then
        return nil
    end
    local needle = (key or ""):lower()
    for header, value in pairs(headers) do
        if tostring(header):lower() == needle then
            return value
        end
    end
    return nil
end

-- SECTION: networking

local function aboutHelpPage()
    return [[
<html>
<head>
<style>
body { color: white; background-color: black; }
h1 { color: yellow; margin-top: 0; margin-bottom: 1; }
h2 { color: orange; margin-top: 1; margin-bottom: 0; }
p { margin-top: 0; margin-bottom: 1; }
code, pre { background-color: gray; color: white; }
a { color: lightblue; }
</style>
</head>
<body>
<h1>CC Browser</h1>
<p>This browser supports a practical subset of HTML and CSS in ComputerCraft.</p>
<h2>Features</h2>
<ul>
<li>URL bar</li>
<li>Back / forward history</li>
<li>Reload</li>
<li>Mouse wheel and keyboard scrolling</li>
<li>Clickable links</li>
</ul>
<h2>Supported HTML</h2>
<p>headings, paragraphs, div/span, lists, links, br, hr, pre/code, and img alt placeholders.</p>
<h2>Supported CSS (subset)</h2>
<p>element/class/id selectors, color/background-color, display, white-space, margin, padding-left, font-weight, text-transform.</p>
<h2>Keys</h2>
<ul>
<li>Enter in URL bar: navigate</li>
<li>Mouse wheel / Up / Down / PageUp / PageDown: scroll</li>
<li>Ctrl+L: focus URL bar</li>
<li>Ctrl+Left and Ctrl+Right: back and forward</li>
<li>F5 or Ctrl+R: reload</li>
<li>Esc or Ctrl+Q: quit</li>
</ul>
<p>Try <a href="https://example.com">https://example.com</a>.</p>
</body>
</html>
]]
end

local function makeErrorPage(url, message)
    local safeUrl = escapeHtml(url or "unknown")
    local safeError = escapeHtml(message or "Unknown error")
    return ([[<html><body><h1>Load Error</h1><p><b>URL:</b> %s</p><pre>%s</pre></body></html>]]):format(safeUrl, safeError)
end

local function readLocalFile(path)
    if path == nil or path == "" then
        return nil, "Empty file path"
    end
    if not fs.exists(path) then
        return nil, "File not found: " .. path
    end
    local handle = fs.open(path, "r")
    if not handle then
        return nil, "Could not open file: " .. path
    end
    local content = handle.readAll() or ""
    handle.close()
    return content
end

local function fetchRemote(url)
    if not http then
        return nil, nil, "HTTP API is disabled"
    end

    local ok, response, err = pcall(http.get, url, nil, true)
    if not ok then
        return nil, nil, tostring(response)
    end
    if not response then
        return nil, nil, err or "Request failed"
    end

    local body = response.readAll() or ""
    local headers = {}
    if response.getResponseHeaders then
        local headersOk, foundHeaders = pcall(response.getResponseHeaders)
        if headersOk and type(foundHeaders) == "table" then
            headers = foundHeaders
        end
    end
    if response.close then
        pcall(response.close)
    end

    return body, headers, nil
end

local function fetchTextResource(url, allowHttpFallback)
    local parsed = parseUrl(url)
    if parsed and parsed.scheme == "about" then
        if url == "about:blank" then
            return "<html><body></body></html>", url, { ["Content-Type"] = "text/html" }, nil
        end
        if url == "about:help" then
            return aboutHelpPage(), url, { ["Content-Type"] = "text/html" }, nil
        end
        return nil, url, nil, "Unsupported about page: " .. url
    end

    if parsed and parsed.scheme == "file" then
        local path = decodeUrlPath(url:sub(8))
        if startsWith(path, "//") then
            path = path:sub(2)
        end
        if path == "" then
            path = "/"
        end
        local body, err = readLocalFile(path)
        if not body then
            return nil, url, nil, err
        end
        return body, url, { ["Content-Type"] = "text/plain" }, nil
    end

    if parsed and (parsed.scheme == "http" or parsed.scheme == "https") then
        local body, headers, err = fetchRemote(url)
        if not body and allowHttpFallback and parsed.scheme == "https" then
            local fallbackUrl = "http://" .. (parsed.authority or "") .. (parsed.path or "/") .. (parsed.suffix or "")
            local fallbackBody, fallbackHeaders, fallbackErr = fetchRemote(fallbackUrl)
            if fallbackBody then
                return fallbackBody, fallbackUrl, fallbackHeaders, nil
            end
            return nil, url, nil, fallbackErr or err
        end
        if not body then
            return nil, url, nil, err
        end
        return body, url, headers, nil
    end

    if fs.exists(url) then
        local body, err = readLocalFile(url)
        if not body then
            return nil, url, nil, err
        end
        return body, "file://" .. url, { ["Content-Type"] = "text/plain" }, nil
    end

    return nil, url, nil, "Unsupported URL scheme"
end

local function looksLikeHtml(body, contentType)
    local ct = (contentType or ""):lower()
    if ct:find("text/html", 1, true) then
        return true
    end
    if ct:find("xhtml", 1, true) then
        return true
    end

    local sample = (body or ""):sub(1, 512):lower()
    if sample:find("<html", 1, true) then
        return true
    end
    if sample:find("<!doctype html", 1, true) then
        return true
    end
    if sample:find("<body", 1, true) then
        return true
    end
    return false
end

-- SECTION: html_parser

local function parseAttributes(raw)
    local attrs = {}
    local i = 1
    local length = #raw

    while i <= length do
        while i <= length and raw:sub(i, i):match("%s") do
            i = i + 1
        end
        if i > length then
            break
        end

        local keyStart, keyEnd = raw:find("^[%w_:%-]+", i)
        if not keyStart then
            i = i + 1
        else
            local key = raw:sub(keyStart, keyEnd):lower()
            i = keyEnd + 1
            while i <= length and raw:sub(i, i):match("%s") do
                i = i + 1
            end
            local value = "true"
            if raw:sub(i, i) == "=" then
                i = i + 1
                while i <= length and raw:sub(i, i):match("%s") do
                    i = i + 1
                end
                local quote = raw:sub(i, i)
                if quote == "\"" or quote == "'" then
                    i = i + 1
                    local endQuote = raw:find(quote, i, true)
                    if endQuote then
                        value = raw:sub(i, endQuote - 1)
                        i = endQuote + 1
                    else
                        value = raw:sub(i)
                        i = length + 1
                    end
                else
                    local valueStart, valueEnd = raw:find("^[^%s>]+", i)
                    if valueStart then
                        value = raw:sub(valueStart, valueEnd)
                        i = valueEnd + 1
                    end
                end
            end
            attrs[key] = decodeEntities(value)
        end
    end

    return attrs
end

local function appendTextNode(parent, text)
    if text == nil or text == "" then
        return
    end
    local last = parent.children[#parent.children]
    if last and last.type == "text" then
        last.text = last.text .. text
    else
        table.insert(parent.children, {
            type = "text",
            text = text,
            parent = parent,
        })
    end
end

local function findTagEnd(html, startIndex)
    local i = startIndex
    local quote = nil
    local length = #html

    while i <= length do
        local ch = html:sub(i, i)
        if quote then
            if ch == quote then
                quote = nil
            end
        else
            if ch == "\"" or ch == "'" then
                quote = ch
            elseif ch == ">" then
                return i
            end
        end
        i = i + 1
    end

    return nil
end

local function parseHTML(html)
    local root = {
        type = "element",
        tag = "document",
        attrs = {},
        children = {},
        parent = nil,
    }

    local stack = { root }
    local lower = html:lower()
    local i = 1
    local length = #html

    while i <= length do
        local lt = html:find("<", i, true)
        if not lt then
            appendTextNode(stack[#stack], html:sub(i))
            break
        end

        if lt > i then
            appendTextNode(stack[#stack], html:sub(i, lt - 1))
        end

        if lower:sub(lt + 1, lt + 3) == "!--" then
            local _, commentEnd = lower:find("-->", lt + 4, true)
            if not commentEnd then
                break
            end
            i = commentEnd + 1
        else
            local gt = findTagEnd(html, lt + 1)
            if not gt then
                appendTextNode(stack[#stack], html:sub(lt))
                break
            end

            local inside = trim(html:sub(lt + 1, gt - 1))
            if inside:sub(1, 1) == "/" then
                local closingTag = trim(inside:sub(2)):lower():match("^([%w_:%-]+)") or ""
                if closingTag ~= "" then
                    while #stack > 1 do
                        local node = stack[#stack]
                        table.remove(stack)
                        if node.tag == closingTag then
                            break
                        end
                    end
                end
                i = gt + 1
            elseif inside:sub(1, 1) == "!" or inside:sub(1, 1) == "?" then
                i = gt + 1
            else
                local selfClosing = false
                if inside:sub(-1) == "/" then
                    selfClosing = true
                    inside = trim(inside:sub(1, -2))
                end

                local tagName, attrRaw = inside:match("^([%w_:%-]+)(.*)$")
                if not tagName then
                    i = gt + 1
                else
                    tagName = tagName:lower()
                    local node = {
                        type = "element",
                        tag = tagName,
                        attrs = parseAttributes(attrRaw or ""),
                        children = {},
                        parent = stack[#stack],
                    }
                    table.insert(stack[#stack].children, node)

                    if RAW_TEXT_TAGS[tagName] and not selfClosing then
                        local closing = "</" .. tagName .. ">"
                        local closeStart, closeEnd = lower:find(closing, gt + 1, true)
                        if closeStart then
                            local rawText = html:sub(gt + 1, closeStart - 1)
                            appendTextNode(node, rawText)
                            i = closeEnd + 1
                        else
                            local rawText = html:sub(gt + 1)
                            appendTextNode(node, rawText)
                            i = length + 1
                        end
                    else
                        if not selfClosing and not VOID_TAGS[tagName] then
                            table.insert(stack, node)
                        end
                        i = gt + 1
                    end
                end
            end
        end
    end

    return root
end

local function walkNode(node, fn)
    fn(node)
    if node.children then
        for _, child in ipairs(node.children) do
            walkNode(child, fn)
        end
    end
end

local function nodeTextContent(node)
    if node.type == "text" then
        return node.text or ""
    end
    local chunks = {}
    for _, child in ipairs(node.children or {}) do
        table.insert(chunks, nodeTextContent(child))
    end
    return table.concat(chunks)
end

-- SECTION: css_parser

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

-- SECTION: renderer

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

-- SECTION: state_and_ui

local function buildDocument(html, baseUrl)
    local root = parseHTML(html)
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
        source = html,
    }
end

local state = {
    currentUrl = "about:help",
    urlInput = "about:help",
    urlCursor = #"about:help" + 1,
    urlOffset = 0,
    urlFocus = false,
    scroll = 0,
    history = {},
    historyIndex = 0,
    document = nil,
    pageLines = { createEmptyLine() },
    loading = false,
    status = "",
    running = true,
    ctrlDown = false,
    ui = {
        back = { x1 = 1, x2 = 3 },
        forward = { x1 = 5, x2 = 7 },
        reload = { x1 = 9, x2 = 11 },
        url = { x1 = 13, x2 = 13 },
    },
}

local function pageHeight()
    local _, h = term.getSize()
    return math.max(1, h - 1)
end

local function maxScroll()
    return math.max(0, #state.pageLines - pageHeight())
end

local function setScroll(value)
    state.scroll = clamp(value, 0, maxScroll())
end

local function canGoBack()
    return state.historyIndex > 1
end

local function canGoForward()
    return state.historyIndex > 0 and state.historyIndex < #state.history
end

local function pushHistory(url)
    for i = #state.history, state.historyIndex + 1, -1 do
        state.history[i] = nil
    end
    table.insert(state.history, url)
    state.historyIndex = #state.history
end

local function layoutUi()
    local w, _ = term.getSize()
    state.ui.back = { x1 = 1, x2 = 3 }
    state.ui.forward = { x1 = 5, x2 = 7 }
    state.ui.reload = { x1 = 9, x2 = 11 }
    state.ui.url = { x1 = 13, x2 = w }
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

local function drawTopBar()
    layoutUi()
    local w, _ = term.getSize()

    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.black)
    term.setCursorPos(1, 1)
    term.write(string.rep(" ", w))

    local function drawButton(region, label, enabled)
        local bg = enabled and colors.lightGray or colors.gray
        local fg = enabled and colors.black or colors.lightGray
        writeClipped(region.x1, 1, "   ", fg, bg)
        writeClipped(region.x1 + 1, 1, label, fg, bg)
    end

    drawButton(state.ui.back, "<", canGoBack())
    drawButton(state.ui.forward, ">", canGoForward())
    drawButton(state.ui.reload, "R", state.document ~= nil)

    if state.ui.url.x1 <= state.ui.url.x2 then
        local fieldWidth = state.ui.url.x2 - state.ui.url.x1 + 1
        local cursor = clamp(state.urlCursor, 1, #state.urlInput + 1)
        state.urlCursor = cursor

        if cursor - state.urlOffset > fieldWidth then
            state.urlOffset = cursor - fieldWidth
        end
        if cursor <= state.urlOffset then
            state.urlOffset = cursor - 1
        end
        if state.urlOffset < 0 then
            state.urlOffset = 0
        end

        local visible = state.urlInput:sub(state.urlOffset + 1, state.urlOffset + fieldWidth)
        if #visible < fieldWidth then
            visible = visible .. string.rep(" ", fieldWidth - #visible)
        end

        writeClipped(state.ui.url.x1, 1, visible, colors.black, colors.white)

        local title = state.document and state.document.title or ""
        if title ~= "" and fieldWidth >= 12 and not state.urlFocus then
            local suffix = " " .. title
            if #suffix < fieldWidth then
                local titleStart = state.ui.url.x2 - #suffix + 1
                writeClipped(titleStart, 1, suffix, colors.gray, colors.white)
            end
        end

        if state.loading then
            local loadingLabel = " loading "
            writeClipped(math.max(state.ui.url.x1, state.ui.url.x2 - #loadingLabel + 1), 1, loadingLabel, colors.yellow, colors.gray)
        end

        if state.urlFocus and not state.loading then
            local cursorX = state.ui.url.x1 + cursor - state.urlOffset - 1
            if cursorX >= state.ui.url.x1 and cursorX <= state.ui.url.x2 then
                term.setCursorPos(cursorX, 1)
                term.setCursorBlink(true)
            else
                term.setCursorBlink(false)
            end
        else
            term.setCursorBlink(false)
        end
    else
        term.setCursorBlink(false)
    end
end

local function drawPage()
    local w, h = term.getSize()
    local firstLine = state.scroll + 1
    local visibleHeight = math.max(1, h - 1)

    for row = 1, visibleHeight do
        local line = state.pageLines[firstLine + row - 1]
        local chars = {}
        local fgs = {}
        local bgs = {}
        for x = 1, w do
            local ch = " "
            local fg = colors.white
            local bg = colors.black
            if line then
                ch = line.chars[x] or " "
                fg = line.fg[x] or colors.white
                bg = line.bg[x] or colors.black
            end
            chars[x] = ch
            fgs[x] = colors.toBlit(fg)
            bgs[x] = colors.toBlit(bg)
        end
        term.setCursorPos(1, row + 1)
        term.blit(table.concat(chars), table.concat(fgs), table.concat(bgs))
    end
end

local function draw()
    drawTopBar()
    drawPage()
end

local function renderDocument()
    if not state.document then
        state.pageLines = { createEmptyLine() }
        setScroll(0)
        return
    end

    local w, _ = term.getSize()
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

    local bodyNode = findFirstTag(state.document.root, "body")
    if bodyNode then
        local bodyStyle = computeStyle(bodyNode, baseStyle, state.document.rules)
        baseStyle.fg = bodyStyle.fg or baseStyle.fg
        baseStyle.bg = bodyStyle.bg or baseStyle.bg
    end

    local writer = createWriter(w, baseStyle.bg)
    local context = {
        currentHref = nil,
        listStack = {},
    }
    local renderRoot = bodyNode or findFirstTag(state.document.root, "html") or state.document.root
    renderNode(renderRoot, baseStyle, state.document.rules, writer, context, state.document.baseUrl)
    trimTrailingBlankLines(writer.lines)
    state.pageLines = writer.lines
    setScroll(state.scroll)
end

-- SECTION: navigation

local function navigate(rawInput, addToHistory, allowFallback)
    local normalized, inferred = normalizeInputUrl(rawInput)

    state.loading = true
    state.status = "Loading " .. normalized
    state.urlInput = normalized
    state.urlCursor = #state.urlInput + 1
    draw()

    local body, finalUrl, headers, err = fetchTextResource(normalized, allowFallback or inferred)
    if not body then
        finalUrl = normalized
        body = makeErrorPage(finalUrl, err or "Unknown error")
        headers = { ["Content-Type"] = "text/html" }
    end

    local contentType = getHeader(headers, "Content-Type") or ""
    if not looksLikeHtml(body, contentType) then
        body = "<html><body><pre>" .. escapeHtml(body) .. "</pre></body></html>"
    end

    state.document = buildDocument(body, finalUrl)
    state.currentUrl = finalUrl
    state.urlInput = finalUrl
    state.urlCursor = #state.urlInput + 1
    state.urlOffset = 0
    state.loading = false
    state.status = state.document.title or ""
    state.urlFocus = false

    if addToHistory then
        pushHistory(finalUrl)
    elseif state.historyIndex > 0 then
        state.history[state.historyIndex] = finalUrl
    else
        pushHistory(finalUrl)
    end

    state.scroll = 0
    renderDocument()
    draw()
end

local function goBack()
    if not canGoBack() then
        return
    end
    state.historyIndex = state.historyIndex - 1
    navigate(state.history[state.historyIndex], false, false)
end

local function goForward()
    if not canGoForward() then
        return
    end
    state.historyIndex = state.historyIndex + 1
    navigate(state.history[state.historyIndex], false, false)
end

local function reloadPage()
    if not state.currentUrl then
        return
    end
    navigate(state.currentUrl, false, false)
end

-- SECTION: events

local function insertUrlText(text)
    if not state.urlFocus then
        return
    end
    local before = state.urlInput:sub(1, state.urlCursor - 1)
    local after = state.urlInput:sub(state.urlCursor)
    state.urlInput = before .. text .. after
    state.urlCursor = state.urlCursor + #text
end

local function deleteUrlBack()
    if state.urlCursor <= 1 then
        return
    end
    local before = state.urlInput:sub(1, state.urlCursor - 2)
    local after = state.urlInput:sub(state.urlCursor)
    state.urlInput = before .. after
    state.urlCursor = state.urlCursor - 1
end

local function deleteUrlForward()
    if state.urlCursor > #state.urlInput then
        return
    end
    local before = state.urlInput:sub(1, state.urlCursor - 1)
    local after = state.urlInput:sub(state.urlCursor + 1)
    state.urlInput = before .. after
end

local function hitRegion(x, region)
    return x >= region.x1 and x <= region.x2
end

local function handleMouseClick(_, x, y)
    if y == 1 then
        if hitRegion(x, state.ui.back) then
            goBack()
            return
        end
        if hitRegion(x, state.ui.forward) then
            goForward()
            return
        end
        if hitRegion(x, state.ui.reload) then
            reloadPage()
            return
        end
        if hitRegion(x, state.ui.url) then
            state.urlFocus = true
            local pos = state.urlOffset + (x - state.ui.url.x1) + 1
            state.urlCursor = clamp(pos, 1, #state.urlInput + 1)
            return
        end
        state.urlFocus = false
        return
    end

    state.urlFocus = false
    local lineIndex = state.scroll + (y - 1)
    local line = state.pageLines[lineIndex]
    local href = line and line.links and line.links[x] or nil
    if href then
        navigate(href, true, false)
    end
end

local function handleMouseScroll(direction, _, y)
    if y <= 1 then
        return
    end
    setScroll(state.scroll + direction)
end

local function focusUrlBar()
    state.urlFocus = true
    state.urlCursor = #state.urlInput + 1
end

local function handleUrlKey(key)
    if key == keys.enter then
        navigate(state.urlInput, true, true)
    elseif key == keys.left then
        state.urlCursor = clamp(state.urlCursor - 1, 1, #state.urlInput + 1)
    elseif key == keys.right then
        state.urlCursor = clamp(state.urlCursor + 1, 1, #state.urlInput + 1)
    elseif key == keys.home then
        state.urlCursor = 1
    elseif key == keys["end"] then
        state.urlCursor = #state.urlInput + 1
    elseif key == keys.backspace then
        deleteUrlBack()
    elseif key == keys.delete then
        deleteUrlForward()
    elseif key == keys.escape then
        state.urlFocus = false
        state.urlInput = state.currentUrl
        state.urlCursor = #state.urlInput + 1
    end
end

local function handleNavigationKey(key)
    if key == keys.up then
        setScroll(state.scroll - 1)
    elseif key == keys.down then
        setScroll(state.scroll + 1)
    elseif key == keys.pageUp then
        setScroll(state.scroll - pageHeight())
    elseif key == keys.pageDown then
        setScroll(state.scroll + pageHeight())
    elseif key == keys.home then
        setScroll(0)
    elseif key == keys["end"] then
        setScroll(maxScroll())
    end
end

local function handleKeyDown(key)
    if key == keys.leftCtrl or key == keys.rightCtrl then
        state.ctrlDown = true
        return
    end

    if key == keys.f5 then
        reloadPage()
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

    if key == keys.tab then
        state.urlFocus = not state.urlFocus
        if state.urlFocus then
            state.urlCursor = #state.urlInput + 1
        end
        return
    end

    if state.urlFocus then
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
    end
end

local function handleChar(character)
    if state.urlFocus then
        insertUrlText(character)
    end
end

local function handlePaste(text)
    if state.urlFocus then
        insertUrlText(text)
    end
end

-- SECTION: entrypoint

local function bootstrap()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    navigate("about:help", true, false)
end

local function main()
    bootstrap()
    while state.running do
        local event = { os.pullEvent() }
        local name = event[1]

        if name == "mouse_click" then
            handleMouseClick(event[2], event[3], event[4])
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
        elseif name == "term_resize" then
            renderDocument()
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

local ok, err = pcall(main)
if not ok then
    term.setCursorBlink(false)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.red)
    term.clear()
    term.setCursorPos(1, 1)
    print(APP_TITLE .. " crashed:")
    print(tostring(err))
end
