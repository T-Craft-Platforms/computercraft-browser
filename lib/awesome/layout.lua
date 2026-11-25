local defaults = [[
html, body, main, article, section, header, footer, nav, aside, div, address, figure, figcaption,
p, h1, h2, h3, h4, h5, h6, pre, ul, ol, li, dl, dt, dd, blockquote, table, tr, thead, tbody,
tfoot, hr, img {display:block}
head, script, link, style, template, noscript, meta, title, svg {display:none}
body {margin:8px}
p, ul, ol, dl, blockquote, figure, pre {margin:0 0 9px}
h1,h2,h3,h4,h5,h6 {font-weight:bold;margin:0 0 6px;line-height:1.15}
h1 {font-size:2em} h2 {font-size:1.55em} h3 {font-size:1.28em}
a {color:#155AB6;text-decoration:underline}
ul,ol {padding-left:14px} li {margin-bottom:3px}
blockquote {padding:5px 9px;background:#EEF2F6;border-left-width:2px;border-color:#9AACC0}
em,i {font-style:italic} strong,b,th {font-weight:bold}
small {font-size:.84em} mark {background:#FFF1AC}
pre,code,kbd,samp {font-family:monospace;background:#EEF2F6}
pre {white-space:pre-wrap;padding:8px;border-radius:3px}
hr {height:1px;background:#B8C3CF;margin:6px 0}
tr {display:grid;gap:1px} td,th {display:block;padding:4px;border:1px solid #D1D9E1}
th {background:#EAF0F5}
]]

local function runeBytes(first)
    if first < 192 then return 1 end
    if first < 224 then return 2 end
    if first < 240 then return 3 end
    return 4
end

return function(css, core)
    local defaultRules = css.rules({defaults})
    for _, rule in ipairs(defaultRules) do rule.userAgent = true end
    local prepared = setmetatable({}, {__mode = "k"})

    local function prepare(document)
        local saved = prepared[document]
        if saved ~= nil then return saved or nil end
        local count, blocked = 0, false
        local body, html
        local function visit(node, depth)
            count = count + 1
            if count > 1800 or depth > 45 then blocked = true; return end
            if node.tag == "body" and not body then body = node end
            if node.tag == "html" and not html then html = node end
            if node.tag == "form" or node.tag == "input" or node.tag == "textarea"
                or node.tag == "select" then blocked = true; return end
            for _, child in ipairs(node.children or {}) do
                if not blocked then visit(child, depth + 1) end
            end
        end
        visit(document.root, 0)
        if blocked then prepared[document] = false; return end
        saved = { node = body or html or document.root, html = html, rules = css.rules(document.stylesheets) }
        prepared[document] = saved
        return saved
    end

    local function layout(document, viewportWidth, viewportHeight, zoom, resources)
        local sheet = prepare(document)
        if not sheet then return nil end
        local rules = css.activeRules(sheet.rules, viewportWidth / zoom)
        local effective = {}
        -- User-agent defaults always precede author declarations.
        for _, rule in ipairs(defaultRules) do effective[#effective + 1] = rule end
        for _, rule in ipairs(rules) do effective[#effective + 1] = rule end
        local commands, words, anchors = {}, {}, {}
        local overflowHidden
        local base = { size=12*zoom, color=0x18242F, background=0xF8FAFC, align="left", space="normal" }
        local exhausted = false
        local function push(command)
            if #commands >= 5000 then exhausted = true; return end
            commands[#commands + 1] = command
        end
        local function length(value, reference, font)
            return css.length(value, reference, font, zoom, viewportWidth, viewportHeight)
        end
        local function style(node, parent)
            local values = css.style(node, effective)
            local variables = {}
            for name, val in pairs(parent.variables or {}) do variables[name] = val end
            for name, val in pairs(values) do
                if name:sub(1,2) == "--" then variables[name] = val end
            end
            for name, val in pairs(values) do
                if name:sub(1,2) ~= "--" then
                    for _ = 1, 6 do
                        local count
                        val, count = val:gsub("var%(%s*(%-%-[%w_-]+)%s*,?%s*([^()]*)%)", function(key, fallback)
                            return variables[key] or fallback
                        end)
                        if count == 0 then break end
                    end
                    values[name] = val
                end
            end
            local size = math.max(8, math.min(64, length(values["font-size"], parent.size, parent.size) or parent.size))
            local background = css.color(values["background-color"], parent.background)
            local weight = values["font-weight"]
            local slope = values["font-style"]
            local decoration = values["text-decoration"]
            local family = values["font-family"]
            local explicitHeight = tonumber(values["line-height"])
            return {
                display = (node.attrs or {}).hidden and "none" or values.display or "inline",
                size=size, color=css.color(values.color, background or parent.background) or parent.color,
                paint=background, background=background or parent.background,
                bold=weight and (weight == "bold" or weight == "bolder" or (tonumber(weight) or 0) >= 600)
                    or (not weight and parent.bold),
                italic=slope and (slope == "italic" or slope == "oblique") or (not slope and parent.italic),
                underline=decoration and decoration:find("underline", 1, true) or (not decoration and parent.underline),
                strike=decoration and decoration:find("line-through", 1, true) or (not decoration and parent.strike),
                mono=family and family:lower():find("mono", 1, true) or (not family and parent.mono),
                align=values["text-align"] or parent.align, space=values["white-space"] or parent.space,
                transform=values["text-transform"] or parent.transform,
                lineHeight = explicitHeight and math.floor(size * explicitHeight + 0.5)
                    or length(values["line-height"], size, size),
                values=values, variables=variables,
            }
        end
        if sheet.html and sheet.html ~= sheet.node then base = style(sheet.html, base) end
        local body = style(sheet.node, base)
        overflowHidden = body.values.overflow == "hidden" or body.values["overflow-y"] == "hidden"

        local function gap(amount, reference, font)
            return math.max(0, length(amount, reference, font) or 0)
        end

        local function flow(x, y, width, parent)
            local row, used, rowHeight, pending = {}, 0, 0, false
            local function newline(force)
                if #row == 0 and not force then pending = false; return end
                local offset = parent.align == "center" and math.floor((width - used) / 2)
                    or parent.align == "right" and width - used or 0
                for _, item in ipairs(row) do
                    item.x, item.y = x + item.x + math.max(0, offset), y + math.floor((rowHeight - item.h) / 2)
                    if item.text:find("%S") then
                        words[#words + 1] = item
                        item.word = #words
                    end
                    push(item)
                end
                y = y + math.max(rowHeight, parent.lineHeight or 0, math.ceil(parent.size))
                row, used, rowHeight, pending = {}, 0, 0, false
            end
            local function append(text, s, href, w, h)
                row[#row + 1] = { kind="text", text=text, x=used, y=0, w=w, h=h, style=s, href=href }
                rowHeight, used = math.max(rowHeight, h, s.lineHeight or 0), used + w
            end
            local function addWord(text, s, href)
                if exhausted or #text > 8192 then return end
                local w, h = resources.measure(text, s)
                local spaceWidth = pending and used > 0 and resources.measure(" ", s) or 0
                local canWrap = s.space ~= "pre" and s.space ~= "nowrap"
                if canWrap and used > 0 and used + spaceWidth + w > width then newline(false); spaceWidth = 0 end
                if spaceWidth > 0 then append(" ", s, href, spaceWidth, h) end
                pending = false
                if not canWrap or w <= width or #text == 1 then append(text, s, href, w, h); return end
                local start, pos, segmentWidth = 1, 1, 0
                while pos <= #text and not exhausted do
                    local stop = math.min(#text + 1, pos + runeBytes(text:byte(pos)))
                    local cw = resources.measure(text:sub(pos, stop - 1), s)
                    if pos > start and segmentWidth + cw > width then
                        append(text:sub(start, pos - 1), s, href, segmentWidth, h)
                        newline(false)
                        start, segmentWidth = pos, 0
                    end
                    segmentWidth, pos = segmentWidth + cw, stop
                end
                if start < pos then append(text:sub(start, pos - 1), s, href, segmentWidth, h) end
            end
            local function text(raw, s, href)
                raw = core.decodeEntities(raw):gsub("\194\160", " ")
                if s.transform == "uppercase" then raw = raw:upper()
                elseif s.transform == "lowercase" then raw = raw:lower() end
                local preserve = s.space == "pre" or s.space == "pre-wrap"
                if preserve then
                    raw = raw:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\t", "    "):gsub("%z", "")
                    for line, ending in (raw .. "\0"):gmatch("([^\n%z]*)([\n%z])") do
                        local offset = 1
                        while offset <= #line do
                            local _, stop = line:find("^%s+", offset)
                            if not stop then _, stop = line:find("^%S+", offset) end
                            addWord(line:sub(offset, stop), s, href)
                            offset = stop + 1
                        end
                        if ending == "\n" then newline(true) end
                    end
                    return
                end
                for token in raw:gmatch("%s*[^%s]+%s*") do
                    local leading, word, trailing = token:match("^(%s*)(%S+)(%s*)$")
                    if #leading > 0 then pending = true end
                    addWord(word, s, href)
                    if #trailing > 0 then pending = true end
                end
                if raw:match("^%s+$") then pending = true end
            end
            return {
                text=text, newline=newline,
                position=function() return y end,
                move=function(nextY) y = nextY end,
            }
        end

        local block
        local function layoutChildren(node, x, y, width, parent, href, depth)
            local cursor = flow(x, y, width, parent)
            local listIndex = 0
            local function visit(child, inherited, link, level)
                if exhausted or level > 45 then return end
                if child.type == "text" then cursor.text(child.text or "", inherited, link); return end
                local current = style(child, inherited)
                if current.display == "none" then return end
                local attributes = child.attrs or {}
                if child.tag == "a" and attributes.href and attributes.href ~= "" then
                    link = attributes.href:sub(1, 1) == "#" and attributes.href
                        or core.resolveRelativeUrl(document.baseUrl, attributes.href)
                end
                if child.tag == "br" then cursor.newline(true); return end
                if current.display ~= "inline" and current.display ~= "inline-block" or child.tag == "img" then
                    cursor.newline(false)
                    if child.tag == "li" then listIndex = listIndex + 1 end
                    local marker = child.tag == "li" and (node.tag == "ol" and tostring(listIndex).."." or "•") or nil
                    cursor.move(block(child, x, cursor.position(), width, current, link, level, marker))
                else
                    if attributes.id then anchors[attributes.id] = cursor.position() end
                    for _, grandchild in ipairs(child.children or {}) do visit(grandchild, current, link, level + 1) end
                end
            end
            for _, child in ipairs(node.children or {}) do visit(child, parent, href, depth + 1) end
            cursor.newline(false)
            return cursor.position()
        end

        local function columnsFor(node, values, children, width, space, font)
            if values.display == "flex" then
                if values["flex-direction"] == "column" then return {width} end
                local count = #children
                if values["flex-wrap"] == "wrap" then
                    local minimum = 64 * zoom
                    for _, child in ipairs(children) do
                        local childValues = css.style(child, effective)
                        minimum = math.max(minimum, gap(childValues["flex-basis"] or childValues["min-width"], width, font))
                    end
                    count = math.max(1, math.min(count, math.floor((width + space) / (minimum + space))))
                end
                local each = math.max(1, math.floor((width - space * (count - 1)) / count))
                local result = {}
                for i = 1, count do result[i] = each end
                return result
            end
            local template = values["grid-template-columns"] or ""
            local count, unit = template:match("^repeat%(%s*(%d+)%s*,%s*([%w%.%%]+)%s*%)$")
            if count then
                local columns = {}
                for i = 1, math.min(12, tonumber(count)) do columns[i] = unit end
                template = table.concat(columns, " ")
            end
            local tracks = {}
            for track in template:gmatch("%S+") do
                if #tracks < 12 then tracks[#tracks + 1] = track end
            end
            if #tracks == 0 then
                local countDefault = node.tag == "tr" and math.min(12, #children) or 1
                for i = 1, countDefault do tracks[i] = "1fr" end
            end
            local fraction, fixed = 0, 0
            for i, track in ipairs(tracks) do
                local part = tonumber(track:match("^([%d%.]+)fr$"))
                if part then fraction = fraction + part else
                    tracks[i] = gap(track, width, font)
                    fixed = fixed + tracks[i]
                end
            end
            local free = math.max(0, width - fixed - space * (#tracks - 1))
            for i, track in ipairs(tracks) do
                if type(track) == "string" then
                    tracks[i] = math.max(1, math.floor(free * tonumber(track:match("^(.-)fr$")) / math.max(1, fraction)))
                else tracks[i] = math.max(1, track) end
            end
            return tracks
        end

        block = function(node, x, y, available, s, href, depth, marker)
            if depth > 45 or exhausted or y > 64000 then exhausted = true; return y end
            local v, font = s.values, s.size
            local function sz(value) return gap(value, available, font) end
            local ml, mr = sz(v["margin-left"]), sz(v["margin-right"])
            local mt, mb = sz(v["margin-top"]), sz(v["margin-bottom"])
            local pl, pr = sz(v["padding-left"]), sz(v["padding-right"])
            local pt, pb = sz(v["padding-top"]), sz(v["padding-bottom"])
            local sides = { "top", "right", "bottom", "left" }
            local borders = {}
            for index, side in ipairs(sides) do borders[index] = sz(v["border-"..side.."-width"]) end
            local edge = pl + pr + borders[2] + borders[4]
            local availableBox = math.max(1, available - ml - mr)
            local boxWidth = length(v.width, available, font)
            local maxWidth = length(v["max-width"], available, font)
            local minWidth = length(v["min-width"], available, font)
            local contentBox = v["box-sizing"] ~= "border-box"
            if boxWidth and contentBox then boxWidth = boxWidth + edge end
            if maxWidth and contentBox then maxWidth = maxWidth + edge end
            if minWidth and contentBox then minWidth = minWidth + edge end
            boxWidth = math.min(availableBox, math.max(1, minWidth or 1, math.min(boxWidth or availableBox, maxWidth or availableBox)))
            if v["margin-left"] == "auto" then
                local extra = availableBox - boxWidth
                ml = ml + (v["margin-right"] == "auto" and math.floor(extra / 2) or extra)
            end
            x, y = x + ml, y + mt
            local innerX, innerY = x + pl + borders[4], y + pt + borders[1]
            local innerWidth = math.max(1, boxWidth - edge)
            local attributes = node.attrs or {}
            if attributes.id then anchors[attributes.id] = y end
            local panel
            if s.paint or borders[1]+borders[2]+borders[3]+borders[4] > 0 then
                panel = {kind="box", x=x, y=y, w=boxWidth, h=0, color=s.paint, edges=borders,
                    border=css.color(v["border-color"], s.background) or s.color, radius=sz(v["border-radius"])}
                push(panel)
            end
            if marker then
                local w, h = resources.measure(marker, s)
                push({kind="text", x=math.max(0, x-w-3), y=innerY, w=w, h=h, text=marker, style=s})
            end
            local finish
            if node.tag == "img" then
                local url = attributes.src and core.resolveRelativeUrl(document.baseUrl, attributes.src)
                local img, intrinsicW, intrinsicH = resources.image(url)
                if img then
                    local requested = v.width and innerWidth or length(attributes.width, available, font) or intrinsicW
                    local w = math.max(1, math.min(innerWidth, requested))
                    local h = math.max(1, length(v.height or attributes.height, viewportHeight, font) or math.floor(intrinsicH * w / intrinsicW))
                    push({kind="image", image=img, x=innerX, y=innerY, w=w, h=math.min(1024, h), href=href})
                    finish = innerY + math.min(1024, h)
                else
                    local label = attributes.alt or "Image"
                    local f = flow(innerX, innerY, innerWidth, s)
                    f.text(label, s, href or url)
                    f.newline(false)
                    finish = f.position()
                end
            elseif s.display == "flex" or s.display == "grid" then
                local children = {}
                for _, child in ipairs(node.children or {}) do
                    if child.type == "element" then
                        local childStyle = style(child, s)
                        if childStyle.display ~= "none" then children[#children + 1] = {child, childStyle} end
                    end
                end
                if #children == 0 then finish = layoutChildren(node, innerX, innerY, innerWidth, s, href, depth)
                else
                    local space = math.min(math.floor(innerWidth/3), gap(v["column-gap"] or v.gap, innerWidth, font))
                    local rowGap = gap(v["row-gap"] or v.gap, innerWidth, font)
                    local elements = {}
                    for i, child in ipairs(children) do elements[i] = child[1] end
                    local widths = columnsFor(node, v, elements, innerWidth, space, font)
                    local column, childX, childY, endRow = 1, innerX, innerY, innerY
                    for _, child in ipairs(children) do
                        endRow = math.max(endRow, block(child[1], childX, childY, widths[column], child[2], href, depth+1))
                        childX = childX + widths[column] + space
                        column = column + 1
                        if column > #widths then
                            column, childX, childY = 1, innerX, endRow + rowGap
                        end
                    end
                    finish = endRow
                end
            else
                finish = layoutChildren(node, innerX, innerY, innerWidth, s, href, depth)
            end
            local vertical = pt+pb+borders[1]+borders[3]
            local minimum = length(v.height or v["min-height"], viewportHeight, font) or 0
            local height = math.max(finish - innerY + vertical, minimum + (contentBox and vertical or 0))
            if panel then panel.h = height end
            return y + height + mb
        end

        local bottom = block(sheet.node, 0, 0, viewportWidth, body, nil, 0)
        if exhausted then return nil end
        return { commands=commands, words=words, anchors=anchors, height=bottom, overflowHidden=overflowHidden,
            background=body.background }
    end

    return layout
end
