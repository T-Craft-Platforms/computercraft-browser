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
<li>Reload/abort button while loading</li>
<li>Tabs with page titles</li>
<li>Tab close buttons</li>
<li>Top-left browser close button</li>
<li>Drag-and-drop tab ordering</li>
<li>Double-click a tab to show its full title</li>
<li>Caret mode (F7) for page text selection</li>
<li>F7 indicator in the URL status area when active</li>
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
<li>F7: toggle caret mode</li>
<li>In caret mode, arrows/home/end/page keys move text selection</li>
<li>Ctrl+A/C/X/V: select all / copy / cut / paste</li>
<li>Ctrl+T: new tab</li>
<li>Ctrl+W: close tab</li>
<li>Ctrl+Tab: next tab</li>
<li>Esc: abort load (while loading) or quit</li>
<li>Ctrl+Q: quit</li>
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

local function layoutUi()
    local w, _ = term.getSize()
    state.ui.closeBrowser = { x1 = 1, x2 = 1, y = 1 }
    state.ui.back = { x1 = 1, x2 = 3, y = 2 }
    state.ui.forward = { x1 = 5, x2 = 7, y = 2 }
    state.ui.reload = { x1 = 9, x2 = 11, y = 2 }
    state.ui.url = { x1 = 13, x2 = w, y = 2 }
    state.ui.newTab = { x1 = math.max(1, w - 2), x2 = w, y = 1 }
    state.ui.tabs = {}
    state.ui.tabClose = {}

    local tabsStart = state.ui.closeBrowser.x2 + 2
    local tabsEnd = state.ui.newTab.x1 - 1
    if tabsEnd < tabsStart or #state.tabs < 1 then
        return
    end

    local x = tabsStart
    local minWidth = 1
    local tabGap = 0
    local tabCount = #state.tabs
    local available = tabsEnd - tabsStart + 1
    local widths = {}
    local preferredWidths = {}
    local preferredTotal = 0

    for index = 1, tabCount do
        local preferred = #tabTitle(state.tabs[index]) + 3
        preferred = math.max(minWidth, preferred)
        preferredWidths[index] = preferred
        preferredTotal = preferredTotal + preferred
    end
    preferredTotal = preferredTotal + (tabCount - 1) * tabGap

    if preferredTotal > available then
        local contentSpace = math.max(tabCount * minWidth, available - ((tabCount - 1) * tabGap))
        local evenWidth = math.max(minWidth, math.floor(contentSpace / tabCount))
        local remainder = contentSpace - (evenWidth * tabCount)
        for index = 1, tabCount do
            widths[index] = evenWidth + ((index <= remainder) and 1 or 0)
        end
    else
        for index = 1, tabCount do
            widths[index] = preferredWidths[index]
        end
    end

    for index = 1, tabCount do
        if x > tabsEnd then
            break
        end
        local remaining = tabCount - index + 1
        local remainingSpace = tabsEnd - x + 1
        local minForRest = (remaining - 1) * (minWidth + tabGap)
        local maxForThis = math.max(minWidth, remainingSpace - minForRest)
        local width = clamp(widths[index] or minWidth, minWidth, maxForThis)
        local x2 = math.min(tabsEnd, x + width - 1)
        width = x2 - x + 1
        state.ui.tabs[index] = { x1 = x, x2 = x2, y = 1, index = index }
        if width >= 4 then
            state.ui.tabClose[index] = { x1 = x2, x2 = x2, y = 1, index = index }
        end
        x = x2 + 1 + tabGap
    end
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

local function tabIndexAt(x)
    for _, region in ipairs(state.ui.tabs) do
        if x >= region.x1 and x <= region.x2 then
            return region.index
        end
    end
    return nil
end

local function tabCloseIndexAt(x)
    for _, region in pairs(state.ui.tabClose) do
        if x >= region.x1 and x <= region.x2 then
            return region.index
        end
    end
    return nil
end

local function tabLabelLimit(index)
    local region = state.ui.tabs[index]
    if not region then
        return 0
    end

    local width = region.x2 - region.x1 + 1
    local closeRegion = state.ui.tabClose[index]
    if closeRegion then
        return math.max(0, width - 3)
    end
    return math.max(0, width - 1)
end

local function revealTabName(index)
    local tabItem = state.tabs[index]
    if not tabItem then
        return
    end

    state.tabNameReveal = {
        index = index,
        text = tabTitle(tabItem),
    }
    if state.tabRevealTimer and os.cancelTimer then
        pcall(os.cancelTimer, state.tabRevealTimer)
    end
    state.tabRevealTimer = os.startTimer(2)
end

local function drawTopBar()
    layoutUi()
    local w, _ = term.getSize()
    local tab = activeTab()

    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.black)
    term.setCursorPos(1, 1)
    term.write(string.rep(" ", w))
    term.setCursorPos(1, 2)
    term.write(string.rep(" ", w))

    writeClipped(state.ui.closeBrowser.x1, state.ui.closeBrowser.y, "x", colors.lightGray, colors.gray)

    for _, region in ipairs(state.ui.tabs) do
        local tabItem = state.tabs[region.index]
        local isActive = region.index == state.activeTab
        local bg = isActive and colors.white or colors.lightGray
        local fg = isActive and colors.black or colors.gray
        local width = region.x2 - region.x1 + 1
        local label = tabTitle(tabItem)
        local closeRegion = state.ui.tabClose[region.index]
        local maxLabel = tabLabelLimit(region.index)

        if #label > maxLabel then
            if maxLabel <= 1 then
                label = label:sub(1, maxLabel)
            else
                label = label:sub(1, maxLabel - 1) .. "~"
            end
        end

        if closeRegion then
            local bodyWidth = math.max(0, width - 2)
            local body = " " .. label
            if #body < bodyWidth then
                body = body .. string.rep(" ", bodyWidth - #body)
            elseif #body > bodyWidth then
                body = body:sub(1, bodyWidth)
            end
            writeClipped(region.x1, 1, body, fg, bg)
            writeClipped(region.x1 + bodyWidth, 1, " ", fg, bg)
            writeClipped(closeRegion.x1, 1, "x", fg, bg)
        else
            local body = " " .. label
            if #body < width then
                body = body .. string.rep(" ", width - #body)
            elseif #body > width then
                body = body:sub(1, width)
            end
            writeClipped(region.x1, 1, body, fg, bg)
        end
    end

    local newWidth = state.ui.newTab.x2 - state.ui.newTab.x1 + 1
    writeClipped(state.ui.newTab.x1, 1, string.rep(" ", newWidth), colors.black, colors.lightGray)
    local plusX = state.ui.newTab.x1 + math.floor((newWidth - 1) / 2)
    writeClipped(plusX, 1, "+", colors.black, colors.lightGray)

    local function drawButton(region, label, enabled, active)
        local bg = colors.gray
        local fg = colors.lightGray
        if enabled then
            bg = active and colors.orange or colors.lightGray
            fg = colors.black
        end
        local width = region.x2 - region.x1 + 1
        writeClipped(region.x1, region.y, string.rep(" ", width), fg, bg)
        local labelX = region.x1 + math.floor((width - #label) / 2)
        writeClipped(labelX, region.y, label, fg, bg)
    end

    drawButton(state.ui.back, "<", canGoBack(tab), false)
    drawButton(state.ui.forward, ">", canGoForward(tab), false)
    drawButton(state.ui.reload, tab.loading and "X" or "R", tab.loading or tab.document ~= nil, tab.loading)

    if state.ui.url.x1 <= state.ui.url.x2 then
        local urlFieldBg = colors.lightGray
        local urlFieldFg = colors.black
        local fieldWidth = state.ui.url.x2 - state.ui.url.x1 + 1
        local cursor = clamp(tab.urlCursor, 1, #tab.urlInput + 1)
        tab.urlCursor = cursor

        if cursor - tab.urlOffset > fieldWidth then
            tab.urlOffset = cursor - fieldWidth
        end
        if cursor <= tab.urlOffset then
            tab.urlOffset = cursor - 1
        end
        if tab.urlOffset < 0 then
            tab.urlOffset = 0
        end

        local visible = tab.urlInput:sub(tab.urlOffset + 1, tab.urlOffset + fieldWidth)
        if #visible < fieldWidth then
            visible = visible .. string.rep(" ", fieldWidth - #visible)
        end

        writeClipped(state.ui.url.x1, 2, visible, urlFieldFg, urlFieldBg)

        local selStart, selEnd = getUrlSelection(tab)
        if selStart then
            local visibleStart = tab.urlOffset + 1
            local visibleEnd = tab.urlOffset + fieldWidth
            local drawStart = math.max(selStart, visibleStart)
            local drawEnd = math.min(selEnd - 1, visibleEnd)
            for charIndex = drawStart, drawEnd do
                local relative = charIndex - visibleStart + 1
                local cursorX = state.ui.url.x1 + relative - 1
                local ch = visible:sub(relative, relative)
                if ch == "" then
                    ch = " "
                end
                writeClipped(cursorX, 2, ch, colors.white, colors.blue)
            end
        end

        local reveal = state.tabNameReveal
        if reveal and reveal.index == state.activeTab and not tab.urlFocus then
            local revealText = reveal.text or tabTitle(tab)
            local revealPadded = " " .. revealText
            if #revealPadded < fieldWidth then
                revealPadded = revealPadded .. string.rep(" ", fieldWidth - #revealPadded)
            end
            writeClipped(state.ui.url.x1, 2, revealPadded, colors.white, colors.blue)
        end

        local rightEdge = state.ui.url.x2
        if tab.loading then
            local loadingLabel = " loading "
            local startX = math.max(state.ui.url.x1, rightEdge - #loadingLabel + 1)
            writeClipped(startX, 2, loadingLabel, colors.yellow, colors.gray)
            rightEdge = startX - 1
        end

        if state.caretMode and rightEdge >= state.ui.url.x1 then
            local caretLabel = " F7 "
            local caretX = math.max(state.ui.url.x1, rightEdge - #caretLabel + 1)
            writeClipped(caretX, 2, caretLabel, colors.black, colors.lime)
        end

        local cursorVisible = false
        if tab.urlFocus then
            local offset = cursor - tab.urlOffset
            local cursorX = state.ui.url.x1 + offset - 1
            if cursorX >= state.ui.url.x1 and cursorX <= state.ui.url.x2 then
                local cursorChar = visible:sub(offset, offset)
                if cursorChar == "" then
                    cursorChar = " "
                end
                writeClipped(cursorX, 2, cursorChar, colors.black, colors.white)
                term.setCursorPos(cursorX, 2)
                cursorVisible = true
            end
        end
        term.setCursorBlink(cursorVisible)
    else
        term.setCursorBlink(false)
    end
end

local function drawPage()
    local w, h = term.getSize()
    local tab = activeTab()
    local firstLine = tab.scroll + 1
    local visibleHeight = math.max(1, h - TOP_BAR_ROWS)
    local selection = state.caretMode and normalizedPageSelection(tab) or nil

    for row = 1, visibleHeight do
        local lineIndex = firstLine + row - 1
        local line = tab.pageLines[lineIndex]
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
            if selection and pageSelectionContains(selection, lineIndex, x) then
                fg = colors.white
                bg = colors.blue
            end
            chars[x] = ch
            fgs[x] = colors.toBlit(fg)
            bgs[x] = colors.toBlit(bg)
        end
        term.setCursorPos(1, row + TOP_BAR_ROWS)
        term.blit(table.concat(chars), table.concat(fgs), table.concat(bgs))
    end
end

local function draw()
    drawTopBar()
    drawPage()
end

local function renderDocument(tab)
    local target = tab or activeTab()
    if not target.document then
        target.pageLines = { createEmptyLine() }
        setScroll(0, target)
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

    local bodyNode = findFirstTag(target.document.root, "body")
    if bodyNode then
        local bodyStyle = computeStyle(bodyNode, baseStyle, target.document.rules)
        baseStyle.fg = bodyStyle.fg or baseStyle.fg
        baseStyle.bg = bodyStyle.bg or baseStyle.bg
    end

    local writer = createWriter(w, baseStyle.bg)
    local context = {
        currentHref = nil,
        listStack = {},
    }
    local renderRoot = bodyNode or findFirstTag(target.document.root, "html") or target.document.root
    renderNode(renderRoot, baseStyle, target.document.rules, writer, context, target.document.baseUrl)
    trimTrailingBlankLines(writer.lines)
    target.pageLines = writer.lines
    setScroll(target.scroll, target)
end

-- SECTION: navigation

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

-- SECTION: events

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

-- SECTION: entrypoint

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

local function main(...)
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

local ok, err = pcall(main, ...)
if not ok then
    term.setCursorBlink(false)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.red)
    term.clear()
    term.setCursorPos(1, 1)
    print(APP_TITLE .. " crashed:")
    print(tostring(err))
end
