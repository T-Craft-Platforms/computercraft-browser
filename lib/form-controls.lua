local function fallbackTrim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function createFormControls(options)
    local clamp = options and options.clamp
    if type(clamp) ~= "function" then
        clamp = function(value, minimum, maximum)
            if value < minimum then
                return minimum
            end
            if value > maximum then
                return maximum
            end
            return value
        end
    end
    local trim = options and options.trim
    if type(trim) ~= "function" then
        trim = fallbackTrim
    end

    local api = {}

    function api.clampCursor(stateEntry)
        local value = tostring(stateEntry.value or "")
        local cursor = tonumber(stateEntry.cursor) or (#value + 1)
        stateEntry.cursor = clamp(math.floor(cursor), 1, #value + 1)
    end

    function api.insert(stateEntry, control, text)
        local value = tostring(stateEntry.value or "")
        local cursor = tonumber(stateEntry.cursor) or (#value + 1)
        cursor = clamp(math.floor(cursor), 1, #value + 1)

        local insertion = tostring(text or "")
        if insertion == "" then
            return
        end

        local before = value:sub(1, cursor - 1)
        local after = value:sub(cursor)
        local merged = before .. insertion .. after
        if control and control.maxLength and tonumber(control.maxLength) then
            merged = merged:sub(1, math.max(0, tonumber(control.maxLength)))
        end
        stateEntry.value = merged
        stateEntry.cursor = clamp(cursor + #insertion, 1, #merged + 1)
    end

    function api.remove(stateEntry, backward)
        local value = tostring(stateEntry.value or "")
        local cursor = tonumber(stateEntry.cursor) or (#value + 1)
        cursor = clamp(math.floor(cursor), 1, #value + 1)
        if backward then
            if cursor <= 1 then
                return
            end
            local before = value:sub(1, cursor - 2)
            local after = value:sub(cursor)
            stateEntry.value = before .. after
            stateEntry.cursor = cursor - 1
        else
            if cursor > #value then
                return
            end
            local before = value:sub(1, cursor - 1)
            local after = value:sub(cursor + 1)
            stateEntry.value = before .. after
            stateEntry.cursor = cursor
        end
        api.clampCursor(stateEntry)
    end

    function api.copyControlDefaults(defaults)
        local nextState = {}
        if type(defaults) ~= "table" then
            return nextState
        end
        for defaultKey in pairs(defaults) do
            if type(defaults[defaultKey]) == "table" then
                local copied = {}
                for i = 1, #defaults[defaultKey] do
                    copied[i] = defaults[defaultKey][i]
                end
                nextState[defaultKey] = copied
            else
                nextState[defaultKey] = defaults[defaultKey]
            end
        end
        return nextState
    end

    function api.resetForm(target, formId, bumpRenderRevision)
        local meta = target and target.formMeta
        local form = meta and meta.formsById and meta.formsById[formId]
        if not form then
            return false
        end

        local controls = meta.controlsByKey or {}
        local formState = target.formState or {}
        target.formState = formState
        for _, key in ipairs(form.controlKeys or {}) do
            local control = controls[key]
            if control then
                formState[key] = api.copyControlDefaults(control.defaults)
            end
        end
        if type(bumpRenderRevision) == "function" then
            bumpRenderRevision(target)
        end
        return true
    end

    function api.pushFormField(fields, name, value)
        fields[#fields + 1] = {
            name = name,
            value = tostring(value or ""),
        }
    end

    function api.collectInputFormField(fields, control, stateEntry, name, key, submitterKey)
        local inputType = tostring(control.inputType or "text"):lower()
        if inputType == "submit" or inputType == "image" then
            if key == submitterKey and name ~= "" then
                api.pushFormField(fields, name, (stateEntry and stateEntry.value) or control.defaultValue or "")
            end
            return
        end
        if inputType == "reset" or inputType == "button" then
            return
        end
        if inputType == "checkbox" or inputType == "radio" then
            if stateEntry and stateEntry.checked and name ~= "" then
                api.pushFormField(fields, name, stateEntry.value or control.defaultValue or "on")
            end
            return
        end
        if name ~= "" then
            api.pushFormField(fields, name, (stateEntry and stateEntry.value) or control.defaultValue or "")
        end
    end

    function api.collectSelectFormField(fields, control, stateEntry, name)
        if name == "" then
            return
        end
        local options = control.options or {}
        if control.multiple then
            for _, selectedIndex in ipairs((stateEntry and stateEntry.selectedIndices) or {}) do
                local option = options[selectedIndex]
                if option then
                    api.pushFormField(fields, name, option.value or option.label or "")
                end
            end
            return
        end
        local selectedIndex = (stateEntry and tonumber(stateEntry.selectedIndex)) or control.defaultSelectedIndex or 1
        selectedIndex = clamp(math.floor(selectedIndex or 1), 1, math.max(1, #options))
        local option = options[selectedIndex]
        if option then
            api.pushFormField(fields, name, option.value or option.label or "")
        end
    end

    function api.collectButtonFormField(fields, control, stateEntry, name, key, submitterKey)
        if name == "" then
            return
        end
        local buttonType = tostring(control.buttonType or "submit"):lower()
        if buttonType == "submit" and key == submitterKey then
            api.pushFormField(fields, name, (stateEntry and stateEntry.value) or control.value or control.defaultValue or "")
        end
    end

    function api.collectFormFields(target, formId, submitterKey)
        local formMeta = (target and target.formMeta) or {}
        local form = formMeta.formsById and formMeta.formsById[formId]
        if not form then
            return {}
        end

        local controls = formMeta.controlsByKey or {}
        local formState = (target and target.formState) or {}
        local fields = {}
        for _, key in ipairs(form.controlKeys or {}) do
            local control = controls[key]
            if control and not control.disabled then
                local stateEntry = formState[key]
                local name = trim(tostring(control.name or ""))
                if control.tag == "input" then
                    api.collectInputFormField(fields, control, stateEntry, name, key, submitterKey)
                elseif control.tag == "textarea" then
                    if name ~= "" then
                        api.pushFormField(fields, name, (stateEntry and stateEntry.value) or control.defaultValue or "")
                    end
                elseif control.tag == "select" then
                    api.collectSelectFormField(fields, control, stateEntry, name)
                elseif control.tag == "button" then
                    api.collectButtonFormField(fields, control, stateEntry, name, key, submitterKey)
                end
            end
        end
        return fields
    end

    return api
end

return createFormControls
