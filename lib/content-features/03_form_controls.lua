    local function renderInputControl(node, style, writer, context)
        local attrs = node.attrs or {}
        local inputType = trim((attrs.type or "text"):lower())
        if inputType == "" then
            inputType = "text"
        end

        local formId = resolveControlFormId(context, node)
        local key = makeControlKey(formId, node)
        local defaultValue = tostring(attrs.value or "")
        if (inputType == "checkbox" or inputType == "radio") and defaultValue == "" then
            defaultValue = "on"
        elseif inputType == "color" then
            defaultValue = normalizePaletteColorName(defaultValue, "white")
        end
        local interactiveEnabled = context.interactiveEnabled ~= false
        local colorOptions = inputType == "color" and SUPPORTED_COLOR_NAMES or nil
        local defaults = {
            value = defaultValue,
            checked = hasBooleanAttr(attrs, "checked"),
            cursor = #defaultValue + 1,
            selectedIndex = 1,
            selectedIndices = {},
            colorIndex = 1,
        }
        if colorOptions then
            for index, optionName in ipairs(colorOptions) do
                if optionName == defaultValue then
                    defaults.colorIndex = index
                    break
                end
            end
        end

        local control = nil
        local stateEntry = nil
        if interactiveEnabled then
            control = {
                key = key,
                formId = formId,
                nodeId = node._nodeId or 0,
                tag = "input",
                inputType = inputType,
                name = attrs.name or "",
                id = attrs.id or "",
                className = attrs.class or "",
                disabled = hasBooleanAttr(attrs, "disabled"),
                readonly = hasBooleanAttr(attrs, "readonly"),
                required = hasBooleanAttr(attrs, "required"),
                placeholder = attrs.placeholder or "",
                maxLength = parseInteger(attrs.maxlength, nil),
                size = parseInteger(attrs.size, nil),
                minValue = tonumber(attrs.min),
                maxValue = tonumber(attrs.max),
                stepValue = tonumber(attrs.step),
                formAction = attrs.formaction or "",
                formMethod = attrs.formmethod or "",
                formEnctype = attrs.formenctype or "",
                defaultValue = defaultValue,
                defaultChecked = defaults.checked,
                defaults = defaults,
                options = nil,
                colorOptions = colorOptions,
            }
            stateEntry = registerControl(context, formId, control)
        else
            stateEntry = {
                value = defaultValue,
                checked = defaults.checked,
                cursor = #defaultValue + 1,
                colorIndex = defaults.colorIndex,
            }
        end

        if inputType == "hidden" then
            return true
        end

        local focused = interactiveEnabled and context.focusControlKey == key
        local disabled = interactiveEnabled and control.disabled or hasBooleanAttr(attrs, "disabled")
        local controlStyle = cloneControlStyle(style, focused, disabled)
        local controlKey = interactiveEnabled and key or nil
        local isBlock = style.display == "block"
        local previousIndent = nil
        if isBlock then
            previousIndent = writer:beginBlock(style)
        end

        if inputType == "checkbox" then
            local marker = stateEntry.checked and "[x]" or "[ ]"
            writer:writeControlText(marker, controlStyle, controlKey)
        elseif inputType == "radio" then
            local marker = stateEntry.checked and "(o)" or "( )"
            writer:writeControlText(marker, controlStyle, controlKey)
        elseif inputType == "submit" or inputType == "reset" or inputType == "button" or inputType == "image" then
            local label = trim(attrs.value or "")
            if label == "" then
                if inputType == "submit" then
                    label = "Submit"
                elseif inputType == "reset" then
                    label = "Reset"
                elseif inputType == "image" then
                    label = "Image"
                else
                    label = "Button"
                end
            end
            writer:writeControlText("[ " .. label .. " ]", controlStyle, controlKey)
        elseif inputType == "color" then
            local selectedName = normalizePaletteColorName(stateEntry.value, "white")
            local selectedIndex = tonumber(stateEntry.colorIndex)
            if colorOptions and #colorOptions > 0 then
                if not selectedIndex then
                    selectedIndex = 1
                    for i, optionName in ipairs(colorOptions) do
                        if optionName == selectedName then
                            selectedIndex = i
                            break
                        end
                    end
                end
                selectedIndex = clamp(math.floor(selectedIndex or 1), 1, #colorOptions)
                selectedName = normalizePaletteColorName(colorOptions[selectedIndex], selectedName)
                stateEntry.colorIndex = selectedIndex
            end
            stateEntry.value = selectedName
            local selectedColor = COLOR_NAME_TO_VALUE[selectedName] or colors.white
            local swatchStyle = cloneControlStyle(style, false, disabled)
            swatchStyle.bg = selectedColor
            swatchStyle.fg = ensureContrastingForeground(controlStyle.fg, selectedColor)
            stateEntry.colorFlyoutOpen = stateEntry.colorFlyoutOpen == true
            local prevKey = controlKey and (key .. "::color:prev") or nil
            local openKey = controlKey and (key .. "::color:open") or nil
            local nextKey = controlKey and (key .. "::color:next") or nil

            writer:writeControlText("<", controlStyle, prevKey)
            writer:writeControlText(" ", controlStyle, openKey)
            writer:writeControlText(selectedName, controlStyle, openKey)
            writer:writeControlText(" ", controlStyle, openKey)
            writer:writeControlText("  ", swatchStyle, openKey)
            writer:writeControlText(" ", controlStyle, openKey)
            writer:writeControlText(">", controlStyle, nextKey)

            if focused and stateEntry.colorFlyoutOpen and colorOptions and #colorOptions > 0 then
                writer:newLine()
                for optionIndex, optionName in ipairs(colorOptions) do
                    local optionColor = COLOR_NAME_TO_VALUE[optionName] or colors.white
                    local optionStyle = cloneControlStyle(style, false, disabled)
                    optionStyle.bg = optionColor
                    optionStyle.fg = ensureContrastingForeground(controlStyle.fg, optionColor)
                    local optionKey = key .. "::color:" .. tostring(optionIndex)
                    local isSelected = optionIndex == stateEntry.colorIndex
                    writer:writeControlText(isSelected and "[" or " ", controlStyle, optionKey)
                    writer:writeControlText("  ", optionStyle, optionKey)
                    writer:writeControlText(isSelected and "]" or " ", controlStyle, optionKey)
                    if optionIndex < #colorOptions then
                        writer:writeControlText(" ", controlStyle, optionKey)
                    end
                end
            end
        else
            local value = tostring(stateEntry.value or "")
            local maxLength = parseInteger(attrs.maxlength, nil)
            if interactiveEnabled and control and control.maxLength then
                maxLength = control.maxLength
            end
            if maxLength and maxLength >= 0 and #value > maxLength then
                value = value:sub(1, maxLength)
                stateEntry.value = value
            end
            stateEntry.cursor = clamp(parseInteger(stateEntry.cursor, (#value + 1)), 1, #value + 1)

            local shown = value
            if inputType == "password" then
                shown = string.rep("*", #value)
            end
            local placeholder = tostring(attrs.placeholder or "")
            local width = clampControlInnerWidth(writer, parseInteger(attrs.size, nil) or 16)
            if interactiveEnabled and control and control.size then
                width = clampControlInnerWidth(writer, control.size or 16)
            end

            if shown == "" and placeholder ~= "" and not focused then
                local placeholderStyle = cloneControlStyle(style, false, disabled)
                placeholderStyle.fg = colors.gray
                local clippedPlaceholder = placeholder
                if #clippedPlaceholder > width then
                    clippedPlaceholder = clippedPlaceholder:sub(1, width)
                end
                writer:writeControlText("[" .. clippedPlaceholder .. "]", placeholderStyle, controlKey)
            else
                local visible = shown
                local cursorDisplay = stateEntry.cursor
                if #visible > width then
                    local start = 1
                    if focused and cursorDisplay > width then
                        start = cursorDisplay - width + 1
                    elseif not focused then
                        start = #visible - width + 1
                    end
                    visible = visible:sub(start, start + width - 1)
                    cursorDisplay = clamp(cursorDisplay - start + 1, 1, #visible + 1)
                end
                if focused then
                    visible = withCursorMarker(visible, cursorDisplay)
                end
                writer:writeControlText("[" .. visible .. "]", controlStyle, controlKey)
            end
        end

        if isBlock then
            writer:endBlock(style, previousIndent)
        end
        return true
    end

    local function collectSelectOptions(node)
        local options = {}
        local function walkOptions(optionNode)
            for _, child in ipairs(optionNode.children or {}) do
                if child.type == "element" then
                    if child.tag == "option" then
                        local attrs = child.attrs or {}
                        local label = trim(decodeEntities(nodeTextContent(child) or ""))
                        local value = tostring(attrs.value or label)
                        options[#options + 1] = {
                            label = label,
                            value = value,
                            selected = hasBooleanAttr(attrs, "selected"),
                            disabled = hasBooleanAttr(attrs, "disabled"),
                        }
                    else
                        walkOptions(child)
                    end
                end
            end
        end
        walkOptions(node)
        if #options == 0 then
            options[1] = { label = "", value = "", selected = true, disabled = false }
        end
        return options
    end

    local function renderSelectControl(node, style, writer, context)
        local attrs = node.attrs or {}
        local formId = resolveControlFormId(context, node)
        local key = makeControlKey(formId, node)
        local options = collectSelectOptions(node)
        local defaultSelectedIndex = 1
        for index, option in ipairs(options) do
            if option.selected then
                defaultSelectedIndex = index
                break
            end
        end

        if context.interactiveEnabled == false then
            local selectedOption = options[defaultSelectedIndex] or options[1]
            local label = tostring(selectedOption and selectedOption.label or "")
            if label == "" then
                label = tostring(selectedOption and selectedOption.value or "")
            end
            local width = clampControlInnerWidth(writer, parseInteger(attrs.size, nil) or math.max(12, #label))
            if #label > width then
                label = label:sub(1, width)
            end
            local isBlock = style.display == "block"
            local previousIndent = nil
            if isBlock then
                previousIndent = writer:beginBlock(style)
            end
            writer:writeControlText(
                "< " .. label .. " >",
                cloneControlStyle(style, false, hasBooleanAttr(attrs, "disabled")),
                nil
            )
            if isBlock then
                writer:endBlock(style, previousIndent)
            end
            return true
        end

        local control = {
            key = key,
            formId = formId,
            nodeId = node._nodeId or 0,
            tag = "select",
            inputType = "select",
            name = attrs.name or "",
            id = attrs.id or "",
            className = attrs.class or "",
            disabled = hasBooleanAttr(attrs, "disabled"),
            readonly = false,
            required = hasBooleanAttr(attrs, "required"),
            multiple = hasBooleanAttr(attrs, "multiple"),
            size = parseInteger(attrs.size, nil),
            options = options,
            defaultSelectedIndex = defaultSelectedIndex,
            defaults = {
                selectedIndex = defaultSelectedIndex,
                selectedIndices = { defaultSelectedIndex },
            },
        }
        local stateEntry = registerControl(context, formId, control)
        stateEntry.selectedIndex = clamp(parseInteger(stateEntry.selectedIndex, defaultSelectedIndex), 1, #options)
        if type(stateEntry.selectedIndices) ~= "table" then
            stateEntry.selectedIndices = { stateEntry.selectedIndex }
        end

        local focused = context.focusControlKey == key
        local controlStyle = cloneControlStyle(style, focused, control.disabled)
        local selectedOption = options[stateEntry.selectedIndex] or options[1]
        local label = tostring(selectedOption and selectedOption.label or "")
        if label == "" then
            label = tostring(selectedOption and selectedOption.value or "")
        end
        local width = clampControlInnerWidth(writer, control.size or math.max(12, #label))
        if #label > width then
            label = label:sub(1, width)
        end

        local isBlock = style.display == "block"
        local previousIndent = nil
        if isBlock then
            previousIndent = writer:beginBlock(style)
        end
        writer:writeControlText("< " .. label .. " >", controlStyle, key)
        if isBlock then
            writer:endBlock(style, previousIndent)
        end
        return true
    end

    local function renderTextAreaControl(node, style, writer, context)
        local attrs = node.attrs or {}
        local formId = resolveControlFormId(context, node)
        local key = makeControlKey(formId, node)
        local defaultValue = decodeEntities(nodeTextContent(node) or "")
        if context.interactiveEnabled == false then
            local display = tostring(defaultValue):gsub("\r", ""):gsub("\n", " ")
            local width = clampControlInnerWidth(writer, parseInteger(attrs.cols, nil) or math.max(18, #display))
            if #display > width then
                display = display:sub(1, width)
            end
            local isBlock = style.display == "block"
            local previousIndent = nil
            if isBlock then
                previousIndent = writer:beginBlock(style)
            end
            writer:writeControlText(
                "[[" .. display .. "]]",
                cloneControlStyle(style, false, hasBooleanAttr(attrs, "disabled")),
                nil
            )
            if isBlock then
                writer:endBlock(style, previousIndent)
            end
            return true
        end
        local control = {
            key = key,
            formId = formId,
            nodeId = node._nodeId or 0,
            tag = "textarea",
            inputType = "textarea",
            name = attrs.name or "",
            id = attrs.id or "",
            className = attrs.class or "",
            disabled = hasBooleanAttr(attrs, "disabled"),
            readonly = hasBooleanAttr(attrs, "readonly"),
            required = hasBooleanAttr(attrs, "required"),
            maxLength = parseInteger(attrs.maxlength, nil),
            rows = parseInteger(attrs.rows, nil),
            cols = parseInteger(attrs.cols, nil),
            defaults = {
                value = defaultValue,
                cursor = #defaultValue + 1,
            },
            defaultValue = defaultValue,
        }
        local stateEntry = registerControl(context, formId, control)
        local value = tostring(stateEntry.value or "")
        if control.maxLength and control.maxLength >= 0 and #value > control.maxLength then
            value = value:sub(1, control.maxLength)
            stateEntry.value = value
        end
        stateEntry.cursor = clamp(parseInteger(stateEntry.cursor, (#value + 1)), 1, #value + 1)

        local display = value:gsub("\r", ""):gsub("\n", " ")
        local focused = context.focusControlKey == key
        if focused then
            display = withCursorMarker(display, stateEntry.cursor)
        end

        local width = clampControlInnerWidth(writer, control.cols or math.max(18, #display))
        if #display > width then
            display = display:sub(1, width)
        end

        local isBlock = style.display == "block"
        local previousIndent = nil
        if isBlock then
            previousIndent = writer:beginBlock(style)
        end
        writer:writeControlText("[[" .. display .. "]]", cloneControlStyle(style, focused, control.disabled), key)
        if isBlock then
            writer:endBlock(style, previousIndent)
        end
        return true
    end

    local function renderButtonControl(node, style, writer, context)
        local attrs = node.attrs or {}
        local formId = resolveControlFormId(context, node)
        local key = makeControlKey(formId, node)
        local buttonType = trim((attrs.type or "submit"):lower())
        if buttonType == "" then
            buttonType = "submit"
        end
        local label = trim(decodeEntities(nodeTextContent(node) or ""))
        if label == "" then
            label = "Button"
        end
        local value = tostring(attrs.value or label)
        if context.interactiveEnabled == false then
            local isBlock = style.display == "block"
            local previousIndent = nil
            if isBlock then
                previousIndent = writer:beginBlock(style)
            end
            writer:writeControlText(
                "[ " .. label .. " ]",
                cloneControlStyle(style, false, hasBooleanAttr(attrs, "disabled")),
                nil
            )
            if isBlock then
                writer:endBlock(style, previousIndent)
            end
            return true
        end
        local control = {
            key = key,
            formId = formId,
            nodeId = node._nodeId or 0,
            tag = "button",
            inputType = buttonType,
            buttonType = buttonType,
            name = attrs.name or "",
            id = attrs.id or "",
            className = attrs.class or "",
            disabled = hasBooleanAttr(attrs, "disabled"),
            readonly = false,
            required = false,
            value = value,
            formAction = attrs.formaction or "",
            formMethod = attrs.formmethod or "",
            formEnctype = attrs.formenctype or "",
            defaults = {
                value = value,
            },
            defaultValue = value,
        }
        registerControl(context, formId, control)

        local focused = context.focusControlKey == key
        local isBlock = style.display == "block"
        local previousIndent = nil
        if isBlock then
            previousIndent = writer:beginBlock(style)
        end
        writer:writeControlText("[ " .. label .. " ]", cloneControlStyle(style, focused, control.disabled), key)
        if isBlock then
            writer:endBlock(style, previousIndent)
        end
        return true
    end

