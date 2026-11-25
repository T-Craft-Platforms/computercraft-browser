local function clamp(value, low, high) return math.max(low, math.min(high, value)) end

return function(typefaces, fontDirectory, layoutPage, screen, generatePalette)
    local fonts, measured = {}, {}
    local document, dimensions, page
    local images = {}
    local measureCount = 0

    local function textStyle(style)
        local fontSize = style.size
        local options = {size=math.min(128, math.max(1, math.floor(fontSize + 0.5))),
            italic=not not style.italic, bold=not not style.bold, underline=not not style.underline,
            strikethrough=not not style.strike}
        if style.mono or not screen.loadFont then return options end
        local chosen, multiplier, distance
        for _, strike in ipairs(typefaces.strikes) do
            local factor = math.max(1, math.floor(fontSize / strike.size + 0.5))
            local score = math.abs(strike.size * factor - fontSize) + (factor - 1) * 0.75
                + (((strike.name == "heading" or strike.name == "title") ~= not not style.bold) and 0.35 or 0)
            if not distance or score < distance then chosen, multiplier, distance = strike, factor, score end
        end
        if not chosen then return options end
        if fonts[chosen.name] == nil then
            local glyphs = {}
            for i, code in ipairs(typefaces.codes) do
                glyphs[code] = { x=(i-1)%16*chosen.stride, y=math.floor((i-1)/16)*chosen.lineHeight,
                    width=chosen.metrics[i*2-1], height=chosen.lineHeight, advance=chosen.metrics[i*2] }
            end
            fonts[chosen.name] = screen.loadFont(fontDirectory .. "/" .. chosen.name .. ".png",
                {lineHeight=chosen.lineHeight, glyphs=glyphs}) or false
        end
        if fonts[chosen.name] then
            options.font = fonts[chosen.name]
            options.size = math.min(128, chosen.lineHeight*multiplier)
            options.bold = not not style.bold and chosen.name ~= "heading" and chosen.name ~= "title"
        end
        return options
    end

    local function measure(text, style)
        local key = table.concat({style.size, tostring(style.mono), tostring(style.bold), tostring(style.italic)}, "/")
        local cache = measured[key]
        if not cache then cache = {}; measured[key] = cache end
        local previous = cache[text]
        if previous then return previous[1], previous[2] end
        local w, h = screen.measureText(text, textStyle(style))
        if measureCount < 3500 then
            cache[text] = {w, h}
            measureCount = measureCount + 1
        end
        return w, h
    end

    local function image(url)
        if not url or not document.inlineImages or not document.inlineImages[url] or not screen.loadImageBytes then return end
        local entry = images[url]
        if entry == nil then
            local resource = screen.loadImageBytes(document.inlineImages[url])
            if resource then
                local w, h = resource.getSize()
                entry = {resource, w, h}
            else entry = false end
            images[url] = entry
        end
        if entry then return entry[1], entry[2], entry[3] end
    end

    local function prepare(tab, width, height, zoom)
        local key = width .. "/" .. height .. "/" .. zoom
        if document ~= tab.document then
            for _, entry in pairs(images) do if entry then entry[1].dispose() end end
            document, dimensions, images = tab.document, nil, {}
        end
        if dimensions ~= key then
            dimensions, measured, measureCount = key, {}, 0
            page = layoutPage(document, width, height, zoom/100, {measure=measure, image=image})
        end
        if page then
            tab.awesomeScroll = clamp(tab.awesomeScroll or 0, 0, page.overflowHidden and 0 or math.max(0, page.height-height))
        end
        return page
    end

    local function rounded(x, y, width, height, radius, color)
        local r = math.min(radius, math.floor((width-1)/2), math.floor((height-1)/2), 24)
        if r <= 0 then screen.fillRect(x,y,width,height,color); return end
        screen.fillRect(x+r,y,width-2*r,height,color)
        screen.fillRect(x,y+r,width,height-2*r,color)
        for _, xx in ipairs({x+r,x+width-r-1}) do
            for _, yy in ipairs({y+r,y+height-r-1}) do screen.fillCircle(xx,yy,r,color) end
        end
    end

    local function render(tab, width, height, top, caret)
        local bottom = top+height
        local scroll = tab.awesomeScroll or 0
        local colors, rgbValues = {}, {}
        local paintedImages = {}
        local function palette(rgb)
            local found = colors[rgb]
            if found then return found end
            if #rgbValues < 200 then
                local index = #rgbValues+32
                rgbValues[#rgbValues+1] = rgb
                colors[rgb] = index
                screen.setPaletteColor(index, rgb)
                return index
            end
            local closest, difference
            for i, existing in ipairs(rgbValues) do
                local score = 0
                for _, power in ipairs({65536, 256, 1}) do
                    local delta = math.floor(existing/power)%256 - math.floor(rgb/power)%256
                    score = score + delta*delta
                end
                if not difference or score < difference then closest, difference = i+31, score end
            end
            colors[rgb] = closest
            return closest
        end
        screen.setClip(0, top, width, height)
        screen.fillRect(0, top, width, height, palette(page.background))
        local selection = caret and tab.awesomeSelection
        local start, finish
        if selection and selection.anchor ~= selection.index then
            start, finish = math.min(selection.anchor, selection.index), math.max(selection.anchor, selection.index)
        end
        for _, command in ipairs(page.commands) do
            local x, y, w, h = command.x, top+command.y-scroll, command.w, command.h
            if y+h > top and y < bottom and x+w > 0 and x < width then
                if command.kind == "box" then
                    if command.color then rounded(x,y,w,h,command.radius,palette(command.color)) end
                    local a,b,c,d = table.unpack(command.edges)
                    if a+b+c+d > 0 then
                        local color = palette(command.border)
                        if a>0 then screen.fillRect(x,y,w,math.min(a,h),color) end
                        if b>0 then screen.fillRect(x+w-math.min(b,w),y,math.min(b,w),h,color) end
                        if c>0 then screen.fillRect(x,y+h-math.min(c,h),w,math.min(c,h),color) end
                        if d>0 then screen.fillRect(x,y,math.min(d,w),h,color) end
                    end
                elseif command.kind == "image" then
                    if not paintedImages[command.image] then
                        if generatePalette then
                            for _, rgb in ipairs(generatePalette(command.image, 48) or {}) do palette(rgb) end
                        end
                        paintedImages[command.image] = true
                    end
                    screen.drawImage(command.image,x,y,{width=w,height=h,dither=true})
                else
                    local options = textStyle(command.style)
                    options.color = palette(command.style.color)
                    if start and command.word and command.word >= start and command.word < finish then
                        screen.fillRect(x,y,w,h,palette(0xC3E1FF))
                        options.color = palette(0x102A46)
                    elseif command.style.paint then
                        options.background = palette(command.style.paint)
                    end
                    screen.text(x,y,command.text,options)
                end
            end
        end
        if selection and not start then
            local word = page.words[selection.index]
            if word then screen.fillRect(word.x, top+word.y-scroll, 1, word.h, palette(0x2059A0)) end
        end
        local maximum = page.overflowHidden and 0 or page.height-height
        if maximum > 0 then
            local thumb = math.max(8, math.floor(height*height/page.height))
            local position = math.floor(scroll/maximum*(height-thumb))
            screen.fillRect(width-3, top+position, 2, thumb, palette(0x8599AB))
        end
        screen.resetClip()
    end

    local function scroll(tab, delta, height)
        tab.awesomeScroll = clamp((tab.awesomeScroll or 0)+delta, 0,
            page.overflowHidden and 0 or math.max(0, page.height-height))
    end

    local function selectionAt(x, y)
        local best, weight
        for index, word in ipairs(page.words) do
            local rowDistance = math.max(0, word.y-y, y-word.y-word.h+1)
            local score = rowDistance*10000 + math.max(0, word.x-x, x-word.x-word.w)
            if not weight or score < weight then best, weight = index, score end
            if score == 0 then break end
        end
        return best
    end

    local function select(tab, index, extend)
        local old = tab.awesomeSelection
        if index then
            tab.awesomeSelection = {anchor=extend and old and old.anchor or index, index=index}
        end
    end

    local function pointer(tab, kind, button, x, y, width, height, caret)
        local documentY = y + (tab.awesomeScroll or 0)
        if kind == "mouse_scroll" then scroll(tab,button*24,height); return end
        if kind == "mouse_up" then
            tab.awesomeDrag, tab.awesomeThumb = nil, nil
            return
        end
        if button ~= 1 then return end
        local maximum = page.overflowHidden and 0 or page.height-height
        if maximum > 0 then
            local thumb = math.max(8, math.floor(height*height/page.height))
            local travel = math.max(1, height-thumb)
            if kind == "mouse_drag" and tab.awesomeThumb then
                tab.awesomeScroll = math.floor(clamp(y-tab.awesomeThumb,0,travel)*maximum/travel + 0.5)
                return
            end
            if kind == "mouse_click" and x >= width-7 then
                local top = math.floor((tab.awesomeScroll or 0)/maximum*travel)
                if y >= top and y < top+thumb then tab.awesomeThumb = y-top
                else scroll(tab,y < top and -height or height,height) end
                return
            end
        end
        if caret and (kind == "mouse_click" or (kind == "mouse_drag" and tab.awesomeDrag)) then
            select(tab, selectionAt(x,documentY), kind == "mouse_drag")
            tab.awesomeDrag = kind == "mouse_click" or tab.awesomeDrag
            return
        end
        if kind ~= "mouse_click" then return end
        for i = #page.commands, 1, -1 do
            local command = page.commands[i]
            if command.href and x >= command.x and x < command.x+command.w
                and documentY >= command.y and documentY < command.y+command.h then
                if command.href:sub(1,1) == "#" then
                    local anchor = command.href:sub(2)
                    local location = page.anchors[anchor] or (anchor == "" and 0)
                    if location ~= nil then scroll(tab,location-(tab.awesomeScroll or 0),height) end
                    return
                end
                return command.href
            end
        end
    end

    local function key(tab, code, height, caret, shift)
        if #page.words > 0 and caret then
            local selection = tab.awesomeSelection
            local index = clamp(selection and selection.index or 1,1,#page.words)
            local word = page.words[index]
            local target
            if code == keys.left then target = index-1
            elseif code == keys.right then target = index+1
            elseif code == keys.up then target = selectionAt(word.x,word.y-word.h)
            elseif code == keys.down then target = selectionAt(word.x,word.y+word.h)
            elseif code == keys.home then target = selectionAt(-1000,word.y)
            elseif code == keys["end"] then target = selectionAt(10000,word.y)
            elseif code == keys.pageUp then target = selectionAt(word.x, word.y-height)
            elseif code == keys.pageDown then target = selectionAt(word.x, word.y+height)
            end
            if target then
                target = clamp(target,1,#page.words)
                select(tab,target,shift)
                local selected = page.words[target]
                local offset = tab.awesomeScroll or 0
                if selected.y < offset then scroll(tab,selected.y-offset,height)
                elseif selected.y+selected.h > offset+height then scroll(tab,selected.y+selected.h-offset-height,height) end
                return true
            end
        end
        if code == keys.up then scroll(tab,-18,height)
        elseif code == keys.down then scroll(tab,18,height)
        elseif code == keys.pageUp then scroll(tab,-height,height)
        elseif code == keys.pageDown then scroll(tab,height,height)
        elseif code == keys.home then scroll(tab,-page.height,height)
        elseif code == keys["end"] then scroll(tab,page.height,height)
        else return false end
        return true
    end

    local function text(tab)
        local selection = tab.awesomeSelection
        if not selection or selection.index == selection.anchor then return "" end
        local parts = {}
        for i = math.min(selection.index,selection.anchor), math.max(selection.index,selection.anchor)-1 do
            if page.words[i] then parts[#parts+1] = page.words[i].text end
        end
        return table.concat(parts," ")
    end

    return { prepare=prepare, render=render, pointer=pointer, key=key, text=text,
        selectAll=function(tab) tab.awesomeSelection={anchor=1,index=#page.words+1} end }
end
