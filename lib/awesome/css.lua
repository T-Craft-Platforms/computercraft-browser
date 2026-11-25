local css = {}
local function trim(text) return (text:gsub("^%s+", ""):gsub("%s+$", "")) end

local named = {
    black=0x000000, white=0xFFFFFF, gray=0x808080, grey=0x808080, silver=0xC0C0C0,
    red=0xFF0000, green=0x008000, blue=0x0000FF, navy=0x000080, teal=0x008080,
    yellow=0xFFFF00, orange=0xFFA500, purple=0x800080, pink=0xFFC0CB,
    lime=0x00FF00, cyan=0x00FFFF, aqua=0x00FFFF, magenta=0xFF00FF,
    lightgray=0xD3D3D3, lightblue=0xADD8E6, darkgray=0xA9A9A9,
    aliceblue=0xF0F8FF, whitesmoke=0xF5F5F5, rebeccapurple=0x663399,
    slategray=0x708090, gold=0xFFD700, brown=0xA52A2A, coral=0xFF7F50,
}

function css.color(value, backdrop)
    if not value then return end
    value = trim(value):lower()
    if named[value] then return named[value] end
    local hex = value:match("^#(%x+)$")
    local rgb, alpha
    if hex then
        if #hex == 3 or #hex == 4 then hex = hex:gsub(".", "%0%0") end
        if #hex == 6 or #hex == 8 then
            rgb, alpha = tonumber(hex:sub(1, 6), 16), tonumber(hex:sub(7, 8), 16)
            if alpha then alpha = alpha / 255 end
        end
    else
        local parts = value:match("^rgba?%((.*)%)$")
        if parts then
            local channels = {}
            for item in parts:gmatch("[^,%s/]+") do
                local number = tonumber(item:match("^([%d%.]+)%%?$"))
                if not number then return end
                channels[#channels + 1] = item:sub(-1) == "%" and number * 2.55 or number
            end
            if #channels == 3 or #channels == 4 then
                rgb = 0
                for i = 1, 3 do rgb = rgb * 256 + math.floor(math.min(255, channels[i]) + 0.5) end
                alpha = channels[4]
            end
        end
    end
    if not rgb or alpha == 0 then return end
    if not alpha or alpha >= 1 then return rgb end
    local result = 0
    for _, factor in ipairs({65536, 256, 1}) do
        local old = math.floor((backdrop or 0xFFFFFF) / factor) % 256
        local nextColor = math.floor(rgb / factor) % 256
        result = result * 256 + math.floor(old + (nextColor - old) * alpha + 0.5)
    end
    return result
end

function css.length(value, reference, font, zoom, viewportWidth, viewportHeight)
    if not value then return end
    local number, unit = trim(value):lower():match("^([%+%-]?[%d%.]+)([%a%%]*)$")
    number = tonumber(number)
    if not number then return end
    local units = { px=zoom, [""]=zoom, ["%"]=reference/100, em=font, rem=12*zoom,
        vw=viewportWidth/100, vh=viewportHeight/100, pt=zoom*4/3 }
    if units[unit] then return math.max(-4096, math.min(8192, math.floor(number * units[unit] + 0.5))) end
end

local function expand(dict, name, value)
    if name == "background" then
        dict["background-color"] = value
    elseif name == "margin" or name == "padding" or name == "border-width" then
        local values = {}
        for word in value:gmatch("%S+") do values[#values + 1] = word end
        local sides = { values[1], values[2] or values[1], values[3] or values[1],
            values[4] or values[2] or values[1] }
        for i, side in ipairs({"top", "right", "bottom", "left"}) do
            dict[name == "border-width" and ("border-"..side.."-width") or (name.."-"..side)] = sides[i]
        end
    elseif name == "border" then
        local width = "1px"
        for word in value:gmatch("%S+") do
            if word == "none" or word == "hidden" then width = "0"
            elseif word:match("^%d") then width = word end
        end
        expand(dict, "border-width", width)
        dict["border-color"] = value:match("(rgba?%b())") or value:match("(#[%x]+)") or value:match("(%a+)%s*$")
    else
        dict[name] = value
    end
end

function css.declarations(source)
    local normal, important = {}, {}
    for name, value in (source or ""):gmatch("([%w%-]+)%s*:%s*([^;{}]+)") do
        value = trim(value)
        local stronger = value:match("^(.-)%s*!%s*important$")
        expand(stronger and important or normal, name:lower(), stronger or value)
    end
    return normal, important
end

local function selector(source)
    local parts, joins = {}, {}
    local weight = 0
    source = trim(source):gsub("%b[]", function(attribute) return attribute:gsub("%s", "\1") end)
    source = source:gsub(">", " > ")
    for token in source:gmatch("%S+") do
        if token == ">" then
            if #parts == 0 then return end
            joins[#parts] = ">"
        else
            local part = { classes={}, ids={}, attrs={} }
            token = token:gsub("\1", " ")
            token = token:gsub("%[(.-)%]", function(attribute)
                local key, value = attribute:match("^%s*([%w_-]+)%s*=%s*(.-)%s*$")
                if key then
                    value = value:gsub("^['\"]", ""):gsub("['\"]$", "")
                else
                    key = trim(attribute):match("^([%w_-]+)$")
                end
                if not key then return "!" end
                part.attrs[#part.attrs + 1] = {key:lower(), value}
                weight = weight + 10
                return ""
            end)
            token = token:gsub(":([%w%-]+)", function(name)
                if name ~= "root" and name ~= "first-child" and name ~= "last-child" then return "!" end
                part.pseudo = name
                weight = weight + 10
                return ""
            end)
            token = token:gsub("([.#])([%w_-]+)", function(prefix, name)
                local list = prefix == "#" and part.ids or part.classes
                list[#list + 1] = name
                weight = weight + (prefix == "#" and 100 or 10)
                return ""
            end)
            if token ~= "" and token ~= "*" then
                if not token:match("^[%a][%w%-]*$") then return end
                part.tag = token:lower()
                weight = weight + 1
            end
            parts[#parts + 1] = part
        end
    end
    if #parts > 0 then return {parts=parts, joins=joins, weight=weight} end
end

local function matchesPart(node, part)
    if not node or node.type ~= "element" or (part.tag and node.tag ~= part.tag) then return false end
    local attributes = node.attrs or {}
    for _, id in ipairs(part.ids) do if attributes.id ~= id then return false end end
    local classes = " " .. (attributes.class or ""):gsub("%s+", " ") .. " "
    for _, class in ipairs(part.classes) do
        if not classes:find(" "..class.." ", 1, true) then return false end
    end
    for _, attribute in ipairs(part.attrs) do
        if attributes[attribute[1]] == nil
            or (attribute[2] and attributes[attribute[1]] ~= attribute[2]) then return false end
    end
    if part.pseudo == "root" then return node.tag == "html" end
    if part.pseudo and node.parent then
        local children = node.parent.children
        local step = part.pseudo == "first-child" and 1 or -1
        for i = (step == 1 and 1 or #children), (step == 1 and #children or 1), step do
            if children[i].type == "element" then return children[i] == node end
        end
        return false
    end
    return true
end

local function matches(node, query, index, failed)
    if not matchesPart(node, query.parts[index]) then return false end
    if index == 1 then return true end
    if failed[index] and failed[index][node] then return false end
    local parent = node.parent
    while parent do
        if matches(parent, query, index - 1, failed) then return true end
        if query.joins[index - 1] == ">" then break end
        parent = parent.parent
    end
    failed[index] = failed[index] or {}
    failed[index][node] = true
    return false
end

function css.rules(sheets)
    local result = {}
    local function parse(source, media, depth)
        if depth > 3 then return end
        source = source:sub(1, 131072):gsub("/%*.-%*/", "")
        local cursor = 1
        while #result < 600 do
            local first, last = source:find("%b{}", cursor)
            if not first then break end
            local prelude = trim(source:sub(cursor, first - 1):match("[^;]*$") or "")
            local body = source:sub(first + 1, last - 1)
            cursor = last + 1
            if prelude:match("^@media%s") then
                parse(body, prelude:sub(7), depth + 1)
            elseif prelude:sub(1, 1) ~= "@" then
                local normal, important = css.declarations(body)
                for part in prelude:gmatch("[^,]+") do
                    local query = selector(part)
                    if query and #query.parts <= 10 then
                        result[#result + 1] = {query=query, normal=normal, important=important, media=media}
                    end
                end
            end
        end
    end
    for _, sheet in ipairs(sheets or {}) do parse(sheet, nil, 0) end
    return result
end

function css.activeRules(rules, width)
    local active = {}
    for _, rule in ipairs(rules) do
        if not rule.media then active[#active+1] = rule else
            for alternative in rule.media:gmatch("[^,]+") do
                local min = tonumber(alternative:match("min%-width%s*:%s*(%d+)%s*px"))
                local max = tonumber(alternative:match("max%-width%s*:%s*(%d+)%s*px"))
                if (min or max or trim(alternative) == "screen")
                    and (not min or width >= min) and (not max or width <= max) then
                    active[#active+1] = rule
                    break
                end
            end
        end
    end
    return active
end

function css.style(node, rules)
    local value, priority = {}, {}
    local function apply(declarations, weight)
        for name, val in pairs(declarations) do
            if not priority[name] or priority[name] <= weight then
                value[name], priority[name] = val, weight
            end
        end
    end
    for _, rule in ipairs(rules) do
        if matches(node, rule.query, #rule.query.parts, {}) then
            local weight = rule.query.weight + (rule.userAgent and -1000 or 0)
            apply(rule.normal, weight)
            apply(rule.important, 10000 + weight)
        end
    end
    if node.attrs and node.attrs.style then
        local normal, important = css.declarations(node.attrs.style)
        apply(normal, 1000)
        apply(important, 11000)
    end
    return value
end

return css
