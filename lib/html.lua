return function(core)
    local trim = core.trim
    local decodeEntities = core.decodeEntities
    local RAW_TEXT_TAGS = core.RAW_TEXT_TAGS
    local VOID_TAGS = core.VOID_TAGS
    local YIELD_EVENT = "__cc_browser_html_yield"
    local YIELD_STEP_BUDGET = 2200
    local yieldSteps = 0

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

    local function parseAttributes(raw)
        local attrs = {}
        local i = 1
        local length = #raw

        while i <= length do
            maybeYield()
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
            maybeYield()
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
            maybeYield()
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
        maybeYield()
        fn(node)
        if node.children then
            for _, child in ipairs(node.children) do
                walkNode(child, fn)
            end
        end
    end

    local function nodeTextContent(node)
        maybeYield()
        if node.type == "text" then
            return node.text or ""
        end
        local chunks = {}
        for _, child in ipairs(node.children or {}) do
            table.insert(chunks, nodeTextContent(child))
        end
        return table.concat(chunks)
    end

    return {
        parseHTML = parseHTML,
        walkNode = walkNode,
        nodeTextContent = nodeTextContent,
    }
end
