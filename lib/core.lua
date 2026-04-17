local M = {}

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

M.VOID_TAGS = VOID_TAGS
M.RAW_TEXT_TAGS = RAW_TEXT_TAGS
M.BLOCK_TAGS = BLOCK_TAGS
M.HEADING_TAGS = HEADING_TAGS

M.clamp = clamp
M.trim = trim
M.startsWith = startsWith
M.decodeEntities = decodeEntities
M.splitByWhitespace = splitByWhitespace
M.escapeHtml = escapeHtml
M.parseCssColor = parseCssColor
M.parseLength = parseLength
M.parseBoxShorthand = parseBoxShorthand
M.transformText = transformText
M.parseUrl = parseUrl
M.resolveRelativeUrl = resolveRelativeUrl
M.decodeUrlPath = decodeUrlPath
M.normalizeInputUrl = normalizeInputUrl
M.getHeader = getHeader

return M
