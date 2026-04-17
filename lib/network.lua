return function(core, options)
    options = options or {}

    local startsWith = core.startsWith
    local parseUrl = core.parseUrl
    local decodeUrlPath = core.decodeUrlPath
    local escapeHtml = core.escapeHtml

    local aboutPagesDir = options.aboutPagesDir or "/src/browser/about-pages"

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

    local function fetchTextResource(url, allowHttpFallback)
        local parsed = parseUrl(url)
        if parsed and parsed.scheme == "about" then
            if url == "about:blank" then
                return "<html><body></body></html>", url, { ["Content-Type"] = "text/html" }, nil
            end

            local pageName = url:match("^about:([^/?#]+)$") or ""
            if not isValidAboutPageName(pageName) then
                return nil, url, nil, "Unsupported about page: " .. url
            end

            local body, err = loadAboutPage(pageName)
            if not body then
                return nil, url, nil, "Unsupported about page: " .. url
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
