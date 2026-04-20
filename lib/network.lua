return function(core, options)
    options = options or {}

    local startsWith = core.startsWith
    local parseUrl = core.parseUrl
    local decodeUrlPath = core.decodeUrlPath
    local escapeHtml = core.escapeHtml
    local trim = core.trim

    local aboutPagesDir = options.aboutPagesDir or "/src/browser/about-pages"
    local aboutApi = options.aboutApi or {}

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

    local function fetchRemote(url, requestOptions)
        if not http then
            return nil, nil, "HTTP API is disabled"
        end

        local method = tostring((requestOptions and requestOptions.method) or "GET"):upper()
        local headers = requestOptions and requestOptions.headers or nil
        local body = requestOptions and requestOptions.body or nil

        local ok, response, err
        if method == "GET" then
            ok, response, err = pcall(http.get, url, headers, true)
        elseif method == "POST" then
            ok, response, err = pcall(http.post, url, tostring(body or ""), headers, true)
        else
            return nil, nil, ("Unsupported HTTP method: %s"):format(method)
        end

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

    local function isValidAboutPageName(name)
        if name == nil or name == "" then
            return false
        end
        if name:find("[/\\]") then
            return false
        end
        if name:find("%.%.", 1, true) then
            return false
        end
        if not name:match("^[%w%._%-]+$") then
            return false
        end
        return true
    end

    local function loadAboutPage(pageName)
        local filePath = fs.combine(aboutPagesDir, pageName .. ".html")
        local body, err = readLocalFile(filePath)
        if not body then
            return nil, err
        end
        return body, nil
    end

    local function decodeQueryComponent(value)
        local text = tostring(value or "")
        text = text:gsub("+", " ")
        return decodeUrlPath(text)
    end

    local function parseQueryString(query)
        local params = {}
        local source = tostring(query or "")
        for token in source:gmatch("([^&]+)") do
            local key, value = token:match("^([^=]+)=(.*)$")
            if not key then
                key = token
                value = ""
            end
            key = decodeQueryComponent(key):lower()
            value = decodeQueryComponent(value)
            if key ~= "" then
                params[key] = value
            end
        end
        return params
    end

    local function mergeParams(base, extra)
        local merged = {}
        for key, value in pairs(base or {}) do
            merged[key] = value
        end
        for key, value in pairs(extra or {}) do
            merged[key] = value
        end
        return merged
    end

    local function parseAboutUrl(url)
        local raw = tostring(url or ""):match("^about:(.*)$") or ""
        local pageName = raw:match("^([^/?#]+)") or ""
        local query = raw:match("%?([^#]*)") or ""
        return pageName, parseQueryString(query)
    end

    local function urlEncode(value)
        local source = tostring(value or "")
        return (source:gsub("([^%w%-_%.~])", function(ch)
            return ("%%%02X"):format(string.byte(ch))
        end))
    end

    local function sortTableKeys(map)
        local keys = {}
        for key, _ in pairs(map or {}) do
            keys[#keys + 1] = key
        end
        table.sort(keys)
        return keys
    end

    local function replaceToken(source, token, value)
        local escaped = token:gsub("([%%%^%$%(%)%.%[%]%*%+%-%?])", "%%%1")
        local replacement = tostring(value or "")
        return (source or ""):gsub(escaped, function()
            return replacement
        end)
    end

    local function normalizeUpdateIntervalMs(rawInterval)
        local value = tonumber(rawInterval)
        if not value then
            return nil
        end
        value = math.floor(value + 0.5)
        if value < 1 then
            return nil
        end
        return value
    end

    local function applyTemplateTokens(template, tokenValues)
        local body = template or ""
        local minUpdateMs = nil

        body = body:gsub("{{([%w_]+)@(%d+)}}", function(tokenName, intervalText)
            local tokenValue = tokenValues and tokenValues[tokenName] or nil
            if tokenValue == nil then
                return ("{{%s@%s}}"):format(tokenName, intervalText)
            end

            local intervalMs = normalizeUpdateIntervalMs(intervalText)
            if intervalMs and ((not minUpdateMs) or intervalMs < minUpdateMs) then
                minUpdateMs = intervalMs
            end
            return tostring(tokenValue)
        end)

        for tokenName, tokenValue in pairs(tokenValues or {}) do
            body = replaceToken(body, "{{" .. tokenName .. "}}", tostring(tokenValue))
        end

        return body, minUpdateMs
    end

    local function renderCenteredLogoAscii()
        local icon = tostring(aboutApi.appIcon or "[CC]")
        local logoLines = {
            "  ____ ____  ",
            " / ___/ ___| ",
            "| |  | |     ",
            "| |__| |___  ",
            " \\____\\____| ",
            "   " .. icon .. "   ",
        }

        local width = 0
        if term and term.getSize then
            local w = term.getSize()
            width = tonumber(w) or 0
        end

        local padded = {}
        for _, line in ipairs(logoLines) do
            local padding = math.max(0, math.floor((width - #line) / 2))
            padded[#padded + 1] = (string.rep(" ", padding) .. line)
        end
        return table.concat(padded, "\n")
    end

    local function listFavorites()
        local favorites = {}
        if type(aboutApi.listFavorites) == "function" then
            local listed = aboutApi.listFavorites()
            if type(listed) == "table" then
                favorites = listed
            end
        end
        return favorites
    end

    local function renderFavoritesItems(favorites)
        local items = {}
        local count = 0
        for _, favorite in ipairs(favorites or {}) do
            local url = tostring((favorite and favorite.url) or "")
            if url ~= "" then
                count = count + 1
                local title = tostring((favorite and favorite.title) or "")
                if title == "" then
                    title = url
                end
                items[#items + 1] = ("<li><a href=\"%s\">%s</a> <code>%s</code></li>")
                    :format(escapeHtml(url), escapeHtml(title), escapeHtml(url))
            end
        end
        if count == 0 then
            items[#items + 1] = "<li><i>No favorites yet.</i></li>"
        end
        return table.concat(items), count
    end

    local function formatMinecraftTime()
        if not os or type(os.time) ~= "function" then
            return "Unavailable"
        end

        local okTime, current = pcall(os.time, "ingame")
        if not okTime or type(current) ~= "number" then
            okTime, current = pcall(os.time)
            if not okTime or type(current) ~= "number" then
                return "Unavailable"
            end
        end

        local normalized = current % 24
        if normalized < 0 then
            normalized = normalized + 24
        end
        local hour = math.floor(normalized)
        local minute = math.floor(((normalized - hour) * 60) + 0.5)
        if minute >= 60 then
            minute = 0
            hour = (hour + 1) % 24
        end

        local dayText = ""
        if type(os.day) == "function" then
            local okDay, day = pcall(os.day, "ingame")
            if not okDay or type(day) ~= "number" then
                okDay, day = pcall(os.day)
            end
            if okDay and type(day) == "number" then
                dayText = (" Day %d"):format(day)
            end
        end

        return ("%02d:%02d%s"):format(hour, minute, dayText)
    end

    local function formatRealTime()
        if not os or type(os.date) ~= "function" then
            return "Unavailable"
        end
        local okDate, formatted = pcall(os.date, "%Y-%m-%d %H:%M:%S")
        if okDate and formatted then
            return tostring(formatted)
        end
        return "Unavailable"
    end

    local function renderHomePage(template, url)
        local favoritesMarkup, favoritesCount = renderFavoritesItems(listFavorites())
        local tokenValues = {
            APP_TITLE = escapeHtml(tostring(aboutApi.appTitle or "CC Browser")),
            APP_VERSION = escapeHtml(tostring(aboutApi.appVersion or "0.0.0")),
            APP_ICON = escapeHtml(tostring(aboutApi.appIcon or "[CC]")),
            CURRENT_URL = escapeHtml(url or "about:home"),
            MINECRAFT_TIME = escapeHtml(formatMinecraftTime()),
            REAL_TIME = escapeHtml(formatRealTime()),
            FAVORITES_COUNT = tostring(favoritesCount),
            FAVORITES_LIST = favoritesMarkup,
        }
        return applyTemplateTokens(template, tokenValues)
    end

    local function renderFavoritesPage(template, url)
        local favoritesMarkup, favoritesCount = renderFavoritesItems(listFavorites())
        local tokenValues = {
            APP_TITLE = escapeHtml(tostring(aboutApi.appTitle or "CC Browser")),
            APP_VERSION = escapeHtml(tostring(aboutApi.appVersion or "0.0.0")),
            APP_ICON = escapeHtml(tostring(aboutApi.appIcon or "[CC]")),
            CURRENT_URL = escapeHtml(url or "about:favorites"),
            FAVORITES_COUNT = tostring(favoritesCount),
            FAVORITES_LIST = favoritesMarkup,
        }
        return applyTemplateTokens(template, tokenValues)
    end

    local settingsStatusMessage = nil
    local settingsStatusUntil = 0

    local function setSettingsStatus(message, durationSeconds)
        settingsStatusMessage = tostring(message or "")
        if os and type(os.clock) == "function" then
            settingsStatusUntil = os.clock() + math.max(0, tonumber(durationSeconds) or 0)
        else
            settingsStatusUntil = 0
        end
    end

    local function activeSettingsStatus()
        if not settingsStatusMessage or settingsStatusMessage == "" then
            return nil
        end
        if not (os and type(os.clock) == "function") then
            return settingsStatusMessage
        end
        if os.clock() <= (settingsStatusUntil or 0) then
            return settingsStatusMessage
        end
        return nil
    end

    local function renderHistoryPage(template, url, params)
        local statusMessage = "Ready."
        local action = trim(tostring(params.action or "")):lower()

        if action == "delete_entry" then
            if type(aboutApi.removeHistoryEntry) ~= "function" then
                statusMessage = "History API is unavailable."
            else
                local ok, err = aboutApi.removeHistoryEntry(params.id or params.entry_id)
                if ok then
                    statusMessage = "History entry removed."
                else
                    statusMessage = tostring(err or "Could not remove history entry.")
                end
            end
        elseif action == "delete_day" then
            if type(aboutApi.clearHistoryDay) ~= "function" then
                statusMessage = "History API is unavailable."
            else
                local ok, err = aboutApi.clearHistoryDay(params.day or "")
                if ok then
                    statusMessage = "History day cleared."
                else
                    statusMessage = tostring(err or "Could not clear history day.")
                end
            end
        elseif action == "clear_all" then
            if type(aboutApi.clearHistory) ~= "function" then
                statusMessage = "History API is unavailable."
            else
                local ok, err = aboutApi.clearHistory()
                if ok then
                    statusMessage = "All history cleared."
                else
                    statusMessage = tostring(err or "Could not clear history.")
                end
            end
        end

        local historyEnabled = true
        if type(aboutApi.getSetting) == "function" then
            local raw = trim(tostring(aboutApi.getSetting("history_enabled") or "true")):lower()
            historyEnabled = not (raw == "false" or raw == "0" or raw == "no" or raw == "off" or raw == "disabled")
        end

        local entries = {}
        if type(aboutApi.listHistory) == "function" then
            local listed = aboutApi.listHistory()
            if type(listed) == "table" then
                entries = listed
            end
        end

        local groupsMarkup = {}
        if #entries == 0 then
            groupsMarkup[#groupsMarkup + 1] = "<p><i>No history yet.</i></p>"
        else
            local currentDay = nil
            local openedList = false
            for _, entry in ipairs(entries) do
                local day = trim(tostring(entry.day or ""))
                if day == "" then
                    day = "Unknown"
                end
                if day ~= currentDay then
                    if openedList then
                        groupsMarkup[#groupsMarkup + 1] = "</ul>"
                    end
                    currentDay = day
                    openedList = true
                    local deleteDayUrl = "about:history?action=delete_day&day=" .. urlEncode(day)
                    groupsMarkup[#groupsMarkup + 1] = ("<h3>%s</h3><p><a href=\"%s\">Delete this day</a></p><ul>")
                        :format(escapeHtml(day), escapeHtml(deleteDayUrl))
                end

                local entryUrl = tostring(entry.url or "")
                local entryTitle = trim(tostring(entry.title or ""))
                if entryTitle == "" then
                    entryTitle = entryUrl
                end
                local timestamp = trim(tostring(entry.timestamp or ""))
                if timestamp == "" then
                    timestamp = day
                end
                local deleteEntryUrl = "about:history?action=delete_entry&id=" .. urlEncode(tostring(entry.id or ""))
                groupsMarkup[#groupsMarkup + 1] =
                    ("<li><code>%s</code> <a href=\"%s\">%s</a> <a href=\"%s\">[delete]</a></li>")
                        :format(escapeHtml(timestamp), escapeHtml(entryUrl), escapeHtml(entryTitle), escapeHtml(deleteEntryUrl))
            end
            if openedList then
                groupsMarkup[#groupsMarkup + 1] = "</ul>"
            end
        end

        local historyHint = historyEnabled
            and "History tracking is enabled."
            or "History tracking is disabled."

        local tokenValues = {
            APP_TITLE = escapeHtml(tostring(aboutApi.appTitle or "CC Browser")),
            APP_VERSION = escapeHtml(tostring(aboutApi.appVersion or "0.0.0")),
            APP_ICON = escapeHtml(tostring(aboutApi.appIcon or "[CC]")),
            CURRENT_URL = escapeHtml(url or "about:history"),
            STATUS_MESSAGE = escapeHtml(statusMessage),
            HISTORY_HINT = escapeHtml(historyHint),
            HISTORY_COUNT = tostring(#entries),
            HISTORY_GROUPS = table.concat(groupsMarkup),
            CLEAR_ALL_URL = escapeHtml("about:history?action=clear_all"),
        }
        return applyTemplateTokens(template, tokenValues)
    end

    local function renderSettingsPage(template, url, params)
        local statusMessage = activeSettingsStatus() or "Ready."
        local action = (params.action or ""):lower()

        if action == "set" then
            local key = params.key or ""
            local value = params.value or ""
            if key == "home_page" then
                local choice = tostring(params.home_page_choice or ""):lower()
                if choice == "about:home" then
                    value = "about:home"
                elseif choice == "about:blank" then
                    value = "about:blank"
                elseif choice == "custom" then
                    value = tostring(params.home_page_custom or "")
                end
            elseif key == "turtle_mode" or key == "virtual_views" then
                key = "turtle_mode"
                local choice = tostring(params.turtle_mode_choice or params.virtual_views_choice or ""):lower()
                if choice == "enabled" then
                    value = "true"
                elseif choice == "disabled" then
                    value = "false"
                end
            elseif key == "usage_guard_enabled" then
                local choice = tostring(params.usage_guard_choice or ""):lower()
                if choice == "enabled" then
                    value = "true"
                elseif choice == "disabled" then
                    value = "false"
                end
            elseif key == "history_enabled" then
                local choice = tostring(params.history_choice or ""):lower()
                if choice == "enabled" then
                    value = "true"
                elseif choice == "disabled" then
                    value = "false"
                end
            elseif key == "persistence_enabled" then
                local choice = tostring(params.persistence_choice or ""):lower()
                if choice == "enabled" then
                    value = "true"
                elseif choice == "disabled" then
                    value = "false"
                end
            end
            if key == "" then
                statusMessage = "Missing setting key."
            elseif key == "home_page" and trim(tostring(value or "")) == "" then
                statusMessage = "Missing home page value."
            elseif type(aboutApi.setSetting) ~= "function" then
                statusMessage = "Settings API is unavailable."
            else
                local ok, err = aboutApi.setSetting(key, value)
                if ok then
                    statusMessage = ("Saved %s = %s"):format(key, value)
                else
                    statusMessage = tostring(err or "Failed to save setting.")
                end
            end
            setSettingsStatus(statusMessage, 3)
        elseif action == "get" then
            local key = params.key or ""
            if key == "" then
                statusMessage = "Missing setting key."
            elseif type(aboutApi.getSetting) ~= "function" then
                statusMessage = "Settings API is unavailable."
            else
                local value = aboutApi.getSetting(key)
                if value == nil then
                    statusMessage = ("No value set for %s"):format(key)
                else
                    statusMessage = ("%s = %s"):format(key, tostring(value))
                end
            end
        end

        local settings = {}
        if type(aboutApi.listSettings) == "function" then
            local listed = aboutApi.listSettings()
            if type(listed) == "table" then
                settings = listed
            end
        end

        local settingsItems = {}
        local settingKeys = sortTableKeys(settings)
        if #settingKeys == 0 then
            settingsItems[#settingsItems + 1] = "<li><i>No settings yet.</i></li>"
        else
            for _, key in ipairs(settingKeys) do
                local value = tostring(settings[key] or "")
                settingsItems[#settingsItems + 1] = ("<li><b>%s</b> = <code>%s</code></li>")
                    :format(escapeHtml(key), escapeHtml(value))
            end
        end

        local paramItems = {}
        local paramKeys = sortTableKeys(params)
        if #paramKeys == 0 then
            paramItems[#paramItems + 1] = "<li><i>No query parameters.</i></li>"
        else
            for _, key in ipairs(paramKeys) do
                paramItems[#paramItems + 1] = ("<li><code>%s</code> = <code>%s</code></li>")
                    :format(escapeHtml(key), escapeHtml(tostring(params[key] or "")))
            end
        end

        local homePageValue = tostring(settings.home_page or "about:home")
        local selectedChoice = tostring(params.home_page_choice or ""):lower()
        if selectedChoice ~= "about:home" and selectedChoice ~= "about:blank" and selectedChoice ~= "custom" then
            if homePageValue == "about:home" then
                selectedChoice = "about:home"
            elseif homePageValue == "about:blank" then
                selectedChoice = "about:blank"
            else
                selectedChoice = "custom"
            end
        end

        local customValue = ""
        if selectedChoice == "custom" then
            customValue = tostring(params.home_page_custom or "")
            if customValue == "" then
                if homePageValue ~= "about:home" and homePageValue ~= "about:blank" then
                    customValue = homePageValue
                end
            end
        elseif homePageValue ~= "about:home" and homePageValue ~= "about:blank" then
            customValue = homePageValue
        end

        local turtleModeValue = tostring(settings.turtle_mode or settings.virtual_views or "false"):lower()
        local turtleModeChoice = tostring(params.turtle_mode_choice or params.virtual_views_choice or ""):lower()
        if turtleModeChoice ~= "enabled" and turtleModeChoice ~= "disabled" then
            if turtleModeValue == "false" or turtleModeValue == "0" or turtleModeValue == "off"
                or turtleModeValue == "no" or turtleModeValue == "disabled" then
                turtleModeChoice = "disabled"
            else
                turtleModeChoice = "enabled"
            end
        end

        local usageGuardValue = tostring(settings.usage_guard_enabled or "true"):lower()
        local usageGuardChoice = tostring(params.usage_guard_choice or ""):lower()
        if usageGuardChoice ~= "enabled" and usageGuardChoice ~= "disabled" then
            if usageGuardValue == "false" or usageGuardValue == "0" or usageGuardValue == "off"
                or usageGuardValue == "no" or usageGuardValue == "disabled" then
                usageGuardChoice = "disabled"
            else
                usageGuardChoice = "enabled"
            end
        end
        local turtleModeEnabled = turtleModeChoice == "enabled"
        if turtleModeEnabled and usageGuardChoice ~= "disabled" then
            usageGuardChoice = "disabled"
            if action == "set" and tostring(params.key or ""):lower() == "usage_guard_enabled" then
                statusMessage = "High-usage crash guard is unavailable while turtle mode is enabled."
                setSettingsStatus(statusMessage, 3)
            end
        end

        local historyValue = tostring(settings.history_enabled or "true"):lower()
        local historyChoice = tostring(params.history_choice or ""):lower()
        if historyChoice ~= "enabled" and historyChoice ~= "disabled" then
            if historyValue == "false" or historyValue == "0" or historyValue == "off"
                or historyValue == "no" or historyValue == "disabled" then
                historyChoice = "disabled"
            else
                historyChoice = "enabled"
            end
        end

        local persistenceValue = tostring(settings.persistence_enabled or "true"):lower()
        local persistenceChoice = tostring(params.persistence_choice or ""):lower()
        if persistenceChoice ~= "enabled" and persistenceChoice ~= "disabled" then
            if persistenceValue == "false" or persistenceValue == "0" or persistenceValue == "off"
                or persistenceValue == "no" or persistenceValue == "disabled" then
                persistenceChoice = "disabled"
            else
                persistenceChoice = "enabled"
            end
        end

        local tokenValues = {
            APP_TITLE = escapeHtml(tostring(aboutApi.appTitle or "CC Browser")),
            APP_VERSION = escapeHtml(tostring(aboutApi.appVersion or "0.0.0")),
            APP_ICON = escapeHtml(tostring(aboutApi.appIcon or "[CC]")),
            CURRENT_URL = escapeHtml(url or "about:settings"),
            STATUS_MESSAGE = escapeHtml(statusMessage),
            LOGO_ASCII = escapeHtml(renderCenteredLogoAscii()),
            HOME_PAGE_RADIO_HOME_CHECKED = selectedChoice == "about:home" and "checked" or "",
            HOME_PAGE_RADIO_BLANK_CHECKED = selectedChoice == "about:blank" and "checked" or "",
            HOME_PAGE_RADIO_CUSTOM_CHECKED = selectedChoice == "custom" and "checked" or "",
            TURTLE_MODE_RADIO_ENABLED_CHECKED = turtleModeChoice == "enabled" and "checked" or "",
            TURTLE_MODE_RADIO_DISABLED_CHECKED = turtleModeChoice == "disabled" and "checked" or "",
            USAGE_GUARD_RADIO_ENABLED_CHECKED = usageGuardChoice == "enabled" and "checked" or "",
            USAGE_GUARD_RADIO_DISABLED_CHECKED = usageGuardChoice == "disabled" and "checked" or "",
            HISTORY_RADIO_ENABLED_CHECKED = historyChoice == "enabled" and "checked" or "",
            HISTORY_RADIO_DISABLED_CHECKED = historyChoice == "disabled" and "checked" or "",
            PERSISTENCE_RADIO_ENABLED_CHECKED = persistenceChoice == "enabled" and "checked" or "",
            PERSISTENCE_RADIO_DISABLED_CHECKED = persistenceChoice == "disabled" and "checked" or "",
            HOME_PAGE_CUSTOM_VALUE = escapeHtml(customValue),
            SETTINGS_LIST = table.concat(settingsItems),
            PARAMS_LIST = table.concat(paramItems),
        }
        local body, minUpdateMs = applyTemplateTokens(template, tokenValues)
        return body, minUpdateMs, statusMessage
    end

    local function fetchTextResource(url, allowHttpFallback, requestOptions)
        local request = requestOptions or {}
        local method = tostring(request.method or "GET"):upper()
        local parsed = parseUrl(url)
        if parsed and parsed.scheme == "about" then
            if url == "about:blank" then
                return "<html><body></body></html>", url, { ["Content-Type"] = "text/html" }, nil
            end

            local pageName, params = parseAboutUrl(url)
            if method == "POST" then
                local requestHeaders = request.headers or {}
                local contentType = tostring(requestHeaders["Content-Type"] or requestHeaders["content-type"] or ""):lower()
                if contentType:find("application/x%-www%-form%-urlencoded", 1, false) then
                    local bodyParams = parseQueryString(request.body or "")
                    params = mergeParams(params, bodyParams)
                end
            end
            if not isValidAboutPageName(pageName) then
                return nil, url, nil, "Unsupported about page: " .. url
            end

            local body, err = loadAboutPage(pageName)
            if not body then
                return nil, url, nil, "Unsupported about page: " .. url
            end
            local aboutUpdateMs = nil
            local responseUrl = url
            local settingsStatus = nil
            if pageName == "settings" then
                responseUrl = "about:settings"
                body, aboutUpdateMs, settingsStatus = renderSettingsPage(body, responseUrl, params)
            elseif pageName == "home" then
                body, aboutUpdateMs = renderHomePage(body, url)
            elseif pageName == "favorites" then
                body, aboutUpdateMs = renderFavoritesPage(body, url)
            elseif pageName == "history" then
                responseUrl = "about:history"
                body, aboutUpdateMs = renderHistoryPage(body, responseUrl, params)
            end
            local headers = { ["Content-Type"] = "text/html" }
            if aboutUpdateMs then
                headers["X-CC-About-Update-Ms"] = tostring(aboutUpdateMs)
            end
            if pageName == "settings" then
                headers["X-CC-Settings-Status"] = tostring(settingsStatus or "")
            end
            return body, responseUrl, headers, nil
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
            local body, headers, err = fetchRemote(url, request)
            if not body and allowHttpFallback and parsed.scheme == "https" then
                local fallbackUrl = "http://" .. (parsed.authority or "") .. (parsed.path or "/") .. (parsed.suffix or "")
                local fallbackBody, fallbackHeaders, fallbackErr = fetchRemote(fallbackUrl, request)
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

    return {
        makeErrorPage = makeErrorPage,
        readLocalFile = readLocalFile,
        fetchRemote = fetchRemote,
        fetchTextResource = fetchTextResource,
        looksLikeHtml = looksLikeHtml,
    }
end
