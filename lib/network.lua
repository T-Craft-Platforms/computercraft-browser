return function(core, options)
    options = options or {}

    local startsWith = core.startsWith
    local parseUrl = core.parseUrl
    local decodeUrlPath = core.decodeUrlPath
    local escapeHtml = core.escapeHtml

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
        return (source or ""):gsub(escaped, value or "")
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

    local function renderSettingsPage(template, url, params)
        local statusMessage = ""
        local action = (params.action or ""):lower()

        if action == "set" then
            local key = params.key or ""
            local value = params.value or ""
            if key == "" then
                statusMessage = "Missing setting key."
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
                local getLink = "about:settings?action=get&key=" .. urlEncode(key)
                settingsItems[#settingsItems + 1] = ("<li><b>%s</b> = <code>%s</code> [<a href=\"%s\">get</a>]</li>")
                    :format(escapeHtml(key), escapeHtml(value), escapeHtml(getLink))
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

        local body = template or ""
        body = replaceToken(body, "{{APP_TITLE}}", escapeHtml(tostring(aboutApi.appTitle or "CC Browser")))
        body = replaceToken(body, "{{APP_VERSION}}", escapeHtml(tostring(aboutApi.appVersion or "0.0.0")))
        body = replaceToken(body, "{{APP_ICON}}", escapeHtml(tostring(aboutApi.appIcon or "[CC]")))
        body = replaceToken(body, "{{CURRENT_URL}}", escapeHtml(url or "about:settings"))
        body = replaceToken(body, "{{STATUS_MESSAGE}}", escapeHtml(statusMessage))
        body = replaceToken(body, "{{LOGO_ASCII}}", escapeHtml(renderCenteredLogoAscii()))
        body = replaceToken(body, "{{SETTINGS_LIST}}", table.concat(settingsItems))
        body = replaceToken(body, "{{PARAMS_LIST}}", table.concat(paramItems))
        return body
    end

    local function fetchTextResource(url, allowHttpFallback)
        local parsed = parseUrl(url)
        if parsed and parsed.scheme == "about" then
            if url == "about:blank" then
                return "<html><body></body></html>", url, { ["Content-Type"] = "text/html" }, nil
            end

            local pageName, params = parseAboutUrl(url)
            if not isValidAboutPageName(pageName) then
                return nil, url, nil, "Unsupported about page: " .. url
            end

            local body, err = loadAboutPage(pageName)
            if not body then
                return nil, url, nil, "Unsupported about page: " .. url
            end
            if pageName == "settings" then
                body = renderSettingsPage(body, url, params)
            end
            return body, url, { ["Content-Type"] = "text/html" }, nil
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

    return {
        makeErrorPage = makeErrorPage,
        readLocalFile = readLocalFile,
        fetchRemote = fetchRemote,
        fetchTextResource = fetchTextResource,
        looksLikeHtml = looksLikeHtml,
    }
end
