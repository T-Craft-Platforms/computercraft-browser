local DEFAULT_REPO_OWNER = "T-Craft-Platforms"
local DEFAULT_REPO_NAME = "computercraft-browser"
local DEFAULT_REF = "main"
local SOURCE_ROOT_CANDIDATES = {
    "",
}
local DEFAULT_INSTALL_DIR = "/ccbrowser"
local REQUIRED_MARKER_FILES = {
    "run.lua",
    "main.lua",
    "lib/core.lua",
    "app/features/01_bootstrap.lua",
}
local DISALLOWED_SOURCE_ROOT_PATTERNS = {
    "^computer/%d+$",
    "^world/",
}

local function ask(label, defaultValue)
    write(label)
    if defaultValue and defaultValue ~= "" then
        write(" [" .. defaultValue .. "]")
    end
    write(": ")
    local input = read()
    if input and input ~= "" then
        return input
    end
    return defaultValue
end

local function parseJson(text)
    if textutils.unserialiseJSON then
        local value, err = textutils.unserialiseJSON(text)
        if value ~= nil then
            return value
        end
        return nil, err
    end
    if textutils.unserializeJSON then
        local value, err = textutils.unserializeJSON(text)
        if value ~= nil then
            return value
        end
        return nil, err
    end
    return nil, "JSON parser is not available in this CC version"
end

local function httpGetText(url)
    local response, err, errResponse = http.get(url, {
        ["User-Agent"] = "ccbrowser-installer",
        ["Accept"] = "application/vnd.github+json",
    })
    if not response then
        if errResponse then
            local code, message = errResponse.getResponseCode()
            local body = errResponse.readAll() or ""
            errResponse.close()
            return nil, ("%s (%s %s): %s"):format(url, tostring(code), tostring(message), body)
        end
        return nil, ("%s: %s"):format(url, tostring(err))
    end

    local body = response.readAll() or ""
    response.close()
    return body
end

local function startsWith(text, prefix)
    return text:sub(1, #prefix) == prefix
end

local function clamp(value, minValue, maxValue)
    if value < minValue then
        return minValue
    end
    if value > maxValue then
        return maxValue
    end
    return value
end

local function ellipsize(text, maxWidth)
    local value = tostring(text or "")
    if maxWidth <= 0 then
        return ""
    end
    if #value <= maxWidth then
        return value
    end
    if maxWidth <= 3 then
        return value:sub(1, maxWidth)
    end
    return value:sub(1, maxWidth - 3) .. "..."
end

local function isDisallowedSourceRoot(root)
    if not root or root == "" then
        return false
    end
    for i = 1, #DISALLOWED_SOURCE_ROOT_PATTERNS do
        if root:match(DISALLOWED_SOURCE_ROOT_PATTERNS[i]) then
            return true
        end
    end
    return false
end

local function trimLine(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function splitPath(path)
    local parts = {}
    for part in tostring(path or ""):gmatch("[^/]+") do
        parts[#parts + 1] = part
    end
    return parts
end

local function globToLuaPattern(glob)
    local source = tostring(glob or "")
    local out = { "^" }
    local i = 1
    while i <= #source do
        local ch = source:sub(i, i)
        if ch == "*" then
            if source:sub(i, i + 1) == "**" then
                out[#out + 1] = ".*"
                i = i + 2
            else
                out[#out + 1] = "[^/]*"
                i = i + 1
            end
        elseif ch == "?" then
            out[#out + 1] = "[^/]"
            i = i + 1
        else
            if ch:match("[%^%$%(%)%%%.%[%]%+%-%]") then
                out[#out + 1] = "%" .. ch
            else
                out[#out + 1] = ch
            end
            i = i + 1
        end
    end
    out[#out + 1] = "$"
    return table.concat(out)
end

local function parseCcignoreRules(text)
    local rules = {}
    for rawLine in tostring(text or ""):gmatch("([^\n]*)\n?") do
        local line = rawLine:gsub("\r", "")
        line = trimLine(line)
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local negated = false
            if line:sub(1, 1) == "!" then
                negated = true
                line = trimLine(line:sub(2))
            end
            if line ~= "" then
                local dirOnly = line:sub(-1) == "/"
                if dirOnly then
                    line = trimLine(line:sub(1, -2))
                end
                local anchored = line:sub(1, 1) == "/"
                if anchored then
                    line = trimLine(line:sub(2))
                end
                if line ~= "" then
                    rules[#rules + 1] = {
                        negated = negated,
                        dirOnly = dirOnly,
                        anchored = anchored,
                        hasSlash = line:find("/", 1, true) ~= nil,
                        pattern = line,
                        luaPattern = globToLuaPattern(line),
                    }
                end
            end
        end
    end
    return rules
end

local function matchRuleAgainstCandidate(rule, candidate)
    if rule.hasSlash then
        if rule.anchored then
            return candidate:match(rule.luaPattern) ~= nil
        end
        if candidate:match(rule.luaPattern) then
            return true
        end
        local start = candidate:find("/", 1, true)
        while start do
            local suffix = candidate:sub(start + 1)
            if suffix:match(rule.luaPattern) then
                return true
            end
            start = candidate:find("/", start + 1, true)
        end
        return false
    end

    local base = candidate:match("([^/]+)$") or candidate
    if rule.anchored then
        if candidate:find("/", 1, true) then
            return false
        end
        return base:match(rule.luaPattern) ~= nil
    end
    return base:match(rule.luaPattern) ~= nil
end

local function isIgnoredByRules(relativePath, rules)
    local parts = splitPath(relativePath)
    if #parts == 0 then
        return false
    end

    local candidates = {}
    local current = ""
    for i = 1, #parts do
        current = current == "" and parts[i] or (current .. "/" .. parts[i])
        candidates[#candidates + 1] = current
    end

    local ignored = false
    for i = 1, #rules do
        local rule = rules[i]
        local limit = rule.dirOnly and (#candidates - 1) or #candidates
        if limit > 0 then
            local matched = false
            for j = 1, limit do
                if matchRuleAgainstCandidate(rule, candidates[j]) then
                    matched = true
                    break
                end
            end
            if matched then
                ignored = not rule.negated
            end
        end
    end
    return ignored
end

local function shouldInstallRelativePath(relative, ignoreMatcher)
    if relative == ".ccignore" then
        return false
    end
    if type(ignoreMatcher) == "function" and ignoreMatcher(relative) then
        return false
    end
    return true
end

local function toRepoPath(root, child)
    if root == "" then
        return child
    end
    return root .. "/" .. child
end

local function buildCcignoreMatcher(owner, repo, ref, tree, sourceRoot)
    local ccignoreRepoPath = toRepoPath(sourceRoot or "", ".ccignore")
    local found = false
    for i = 1, #tree do
        local entry = tree[i]
        if entry.type == "blob" and entry.path == ccignoreRepoPath then
            found = true
            break
        end
    end
    if not found then
        return function(relative)
            return relative == ".ccignore"
        end
    end

    local rawUrl = ("https://raw.githubusercontent.com/%s/%s/%s/%s")
        :format(owner, repo, ref, ccignoreRepoPath)
    local text, err = httpGetText(rawUrl)
    if not text then
        return function(relative)
            return relative == ".ccignore"
        end, "Failed to load .ccignore: " .. tostring(err)
    end

    local rules = parseCcignoreRules(text)
    return function(relative)
        if relative == ".ccignore" then
            return true
        end
        return isIgnoredByRules(relative, rules)
    end
end

local function hasRequiredFiles(tree, root)
    local wanted = {}
    for i = 1, #REQUIRED_MARKER_FILES do
        wanted[toRepoPath(root, REQUIRED_MARKER_FILES[i])] = true
    end

    local found = 0
    for i = 1, #tree do
        local entry = tree[i]
        if entry.type == "blob" and wanted[entry.path] then
            found = found + 1
            wanted[entry.path] = nil
        end
    end
    return found == #REQUIRED_MARKER_FILES
end

local function pickSourceRoot(tree)
    for i = 1, #SOURCE_ROOT_CANDIDATES do
        local root = SOURCE_ROOT_CANDIDATES[i]
        if hasRequiredFiles(tree, root) then
            return root
        end
    end

    local fallbackByParent = {}
    for i = 1, #tree do
        local entry = tree[i]
        if entry.type == "blob" and type(entry.path) == "string" then
            local name = entry.path
            if name:sub(-8) == "/run.lua" or name == "run.lua" or name:sub(-9) == "/main.lua" or name == "main.lua" then
                local parent = name:match("^(.*)/[^/]+$") or ""
                if not isDisallowedSourceRoot(parent) then
                    fallbackByParent[parent] = (fallbackByParent[parent] or 0) + 1
                end
            end
        end
    end

    local bestRoot = nil
    local bestScore = -1
    for root, score in pairs(fallbackByParent) do
        if score > bestScore then
            bestRoot = root
            bestScore = score
        end
    end

    if bestRoot then
        return bestRoot
    end

    return nil, "Could not find browser files in allowed source roots"
end

local function fetchTree(owner, repo, branch)
    local treeUrl = ("https://api.github.com/repos/%s/%s/git/trees/%s?recursive=1")
        :format(owner, repo, textutils.urlEncode(branch))
    local treeText, treeErr = httpGetText(treeUrl)
    if not treeText then
        return nil, treeErr
    end

    local payload, parseErr = parseJson(treeText)
    if not payload then
        return nil, "Failed to parse GitHub API response: " .. tostring(parseErr)
    end
    if type(payload.tree) ~= "table" then
        return nil, "GitHub API response did not contain a file tree"
    end
    return payload.tree
end

local function fetchLatestReleaseTag(owner, repo)
    local releaseUrl = ("https://api.github.com/repos/%s/%s/releases/latest"):format(owner, repo)
    local releaseText, releaseErr = httpGetText(releaseUrl)
    if not releaseText then
        return nil, releaseErr
    end

    local payload, parseErr = parseJson(releaseText)
    if not payload then
        return nil, "Failed to parse latest release response: " .. tostring(parseErr)
    end

    local tag = type(payload.tag_name) == "string" and payload.tag_name or nil
    if not tag or tag == "" then
        return nil, "Latest release response did not contain a tag"
    end
    return tag
end

local function fetchTags(owner, repo)
    local tags = {}
    for page = 1, 20 do
        local tagsUrl = ("https://api.github.com/repos/%s/%s/tags?per_page=100&page=%d")
            :format(owner, repo, page)
        local tagsText, tagsErr = httpGetText(tagsUrl)
        if not tagsText then
            if page == 1 then
                return nil, tagsErr
            end
            break
        end

        local payload, parseErr = parseJson(tagsText)
        if type(payload) ~= "table" then
            return nil, "Failed to parse tags response: " .. tostring(parseErr)
        end
        if #payload == 0 then
            break
        end

        for i = 1, #payload do
            local entry = payload[i]
            local name = entry and entry.name
            if type(name) == "string" and name ~= "" then
                tags[#tags + 1] = name
            end
        end

        if #payload < 100 then
            break
        end
    end
    return tags
end

local function fetchBranches(owner, repo)
    local branches = {}
    for page = 1, 20 do
        local branchUrl = ("https://api.github.com/repos/%s/%s/branches?per_page=100&page=%d")
            :format(owner, repo, page)
        local branchText, branchErr = httpGetText(branchUrl)
        if not branchText then
            if page == 1 then
                return nil, branchErr
            end
            break
        end

        local payload, parseErr = parseJson(branchText)
        if type(payload) ~= "table" then
            return nil, "Failed to parse branches response: " .. tostring(parseErr)
        end
        if #payload == 0 then
            break
        end

        for i = 1, #payload do
            local entry = payload[i]
            local name = entry and entry.name
            if type(name) == "string" and name ~= "" then
                branches[#branches + 1] = name
            end
        end

        if #payload < 100 then
            break
        end
    end
    return branches
end

local function buildVersionOptions(owner, repo, preferredDefault)
    local notes = {}
    local releases = {}
    local branches = {}
    local seenReleases = {}
    local seenBranches = {}

    local function addRelease(ref, suffix)
        if type(ref) ~= "string" or ref == "" or seenReleases[ref] then
            return
        end
        seenReleases[ref] = true
        releases[#releases + 1] = {
            ref = ref,
            label = ref .. (suffix or ""),
        }
    end

    local function addBranch(ref, suffix)
        if type(ref) ~= "string" or ref == "" or seenBranches[ref] then
            return
        end
        seenBranches[ref] = true
        branches[#branches + 1] = {
            ref = ref,
            label = ref .. (suffix or ""),
        }
    end

    local latestTag, latestErr = fetchLatestReleaseTag(owner, repo)
    if latestTag and latestTag ~= "" then
        local suffix = " [latest]"
        if latestTag == preferredDefault then
            suffix = suffix .. " [default]"
        end
        addRelease(latestTag, suffix)
    elseif latestErr and latestErr ~= "" then
        notes[#notes + 1] = "Latest release lookup failed."
    end

    local tags, tagsErr = fetchTags(owner, repo)
    if tags then
        for i = 1, #tags do
            local suffix = tags[i] == preferredDefault and " [default]" or ""
            addRelease(tags[i], suffix)
        end
    elseif tagsErr and tagsErr ~= "" then
        notes[#notes + 1] = "Release tag list unavailable."
    end

    local branchList, branchesErr = fetchBranches(owner, repo)
    if branchList then
        for i = 1, #branchList do
            local suffix = branchList[i] == preferredDefault and " [default]" or ""
            addBranch(branchList[i], suffix)
        end
    elseif branchesErr and branchesErr ~= "" then
        notes[#notes + 1] = "Branch list unavailable."
    end

    addBranch(preferredDefault or DEFAULT_REF, " [default]")

    return releases, branches, table.concat(notes, " ")
end

local function resolveRef(owner, repo, value)
    local requested = tostring(value or "")
    if requested == "" then
        return nil, "Empty git ref"
    end

    local lowered = requested:lower()
    if lowered == "latest" or lowered == "latest-release" then
        local latestTag, latestErr = fetchLatestReleaseTag(owner, repo)
        if latestTag and latestTag ~= "" then
            return latestTag
        end
        return nil, "Could not resolve latest release tag: " .. tostring(latestErr)
    end

    return requested
end

local function listFilesFromTree(tree, sourceRoot, ignoreMatcher)
    local files = {}
    local prefix = sourceRoot == "" and "" or (sourceRoot .. "/")
    for i = 1, #tree do
        local entry = tree[i]
        if entry.type == "blob" and type(entry.path) == "string" and startsWith(entry.path, prefix) then
            local relative
            if sourceRoot == "" then
                relative = entry.path
            else
                relative = entry.path:sub(#prefix + 1)
            end
            if relative ~= "" and shouldInstallRelativePath(relative, ignoreMatcher) then
                files[#files + 1] = {
                    repoPath = entry.path,
                    relative = relative,
                }
            end
        end
    end

    table.sort(files, function(a, b)
        return a.relative < b.relative
    end)

    return files
end

local function writeFile(path, content)
    local dir = fs.getDir(path)
    if dir and dir ~= "" and not fs.exists(dir) then
        fs.makeDir(dir)
    end
    local handle, err = fs.open(path, "w")
    if not handle then
        return nil, err
    end
    handle.write(content)
    handle.close()
    return true
end

local function formatBytes(value)
    local bytes = tonumber(value)
    if not bytes then
        return "unknown"
    end
    if bytes < 1024 then
        return ("%d B"):format(math.floor(bytes))
    end
    if bytes < (1024 * 1024) then
        return ("%.1f KiB"):format(bytes / 1024)
    end
    return ("%.1f MiB"):format(bytes / (1024 * 1024))
end

local function getFreeSpaceBytes(path)
    if not fs or type(fs.getFreeSpace) ~= "function" then
        return nil
    end
    local ok, free = pcall(fs.getFreeSpace, path)
    if not ok then
        return nil
    end
    if type(free) == "number" then
        return free
    end
    return nil
end

local function isOutOfSpaceError(err)
    local text = tostring(err or ""):lower()
    return text:find("out of space", 1, true) ~= nil
        or text:find("no space", 1, true) ~= nil
        or text:find("disk full", 1, true) ~= nil
end

local function chooseVersionWizard(releaseOptions, branchOptions, defaultRef, noteText)
    local oldBg = term.getBackgroundColor()
    local oldFg = term.getTextColor()
    local oldBlink = term.getCursorBlink and term.getCursorBlink() or false
    local width, height = term.getSize()
    local listTop = 4
    local listBottom = math.max(listTop, height - 4)
    local listHeight = listBottom - listTop + 1
    local listLeft = 2
    local listRight = math.max(listLeft, width - 2)
    local contentRight = math.max(listLeft, listRight - 2)
    local customLabel = " Custom version "
    local exitLabel = " Exit "
    local buttonY = height
    local buttonX = math.floor((width - #customLabel) / 2)
    local buttonW = #customLabel
    local exitButtonX = 2
    local exitButtonW = #exitLabel
    local customHovered = false
    local exitHovered = false
    local customMode = false
    local customInput = defaultRef or DEFAULT_REF
    local customCursor = #customInput + 1
    local customError = nil
    local tabNames = { " Releases ", " Branches " }
    local activeTab = 1
    local tabs = {
        {
            name = tabNames[1],
            options = releaseOptions or {},
            selected = 1,
            topIndex = 1,
        },
        {
            name = tabNames[2],
            options = branchOptions or {},
            selected = 1,
            topIndex = 1,
        },
    }
    local tabHitboxes = {}
    local customHitboxes = {
        input = nil,
        ok = nil,
        cancel = nil,
    }

    if #tabs[1].options == 0 then
        tabs[1].options = {
            { ref = "latest", label = "latest [no release tags found]" },
        }
        activeTab = 2
    end
    if #tabs[2].options == 0 then
        tabs[2].options = {
            { ref = defaultRef or DEFAULT_REF, label = (defaultRef or DEFAULT_REF) .. " [default]" },
        }
    end

    local function restoreTerm()
        term.setCursorBlink(oldBlink)
        term.setBackgroundColor(oldBg)
        term.setTextColor(oldFg)
        term.clear()
        term.setCursorPos(1, 1)
    end

    local function currentTab()
        return tabs[activeTab]
    end

    local function ensureVisible()
        local tab = currentTab()
        local optionCount = #tab.options
        local maxTop = math.max(1, optionCount - listHeight + 1)
        tab.selected = clamp(tab.selected, 1, optionCount)
        if tab.selected < tab.topIndex then
            tab.topIndex = tab.selected
        elseif tab.selected > (tab.topIndex + listHeight - 1) then
            tab.topIndex = tab.selected - listHeight + 1
        end
        tab.topIndex = clamp(tab.topIndex, 1, maxTop)
    end

    local function writeAt(x, y, fg, bg, text)
        term.setCursorPos(x, y)
        term.setTextColor(fg)
        term.setBackgroundColor(bg)
        write(text)
    end

    local function clearLine(y, bg)
        writeAt(1, y, colors.white, bg, string.rep(" ", width))
    end

    local function trimWhitespace(value)
        return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
    end

    local function drawTabs()
        clearLine(2, colors.black)
        tabHitboxes = {}
        local x = 2
        for i = 1, #tabs do
            local tab = tabs[i]
            local isActive = i == activeTab
            local fg = isActive and colors.white or colors.lightGray
            local bg = isActive and colors.blue or colors.gray
            writeAt(x, 2, fg, bg, tab.name)
            tabHitboxes[i] = {
                x1 = x,
                x2 = x + #tab.name - 1,
            }
            x = x + #tab.name + 1
        end
    end

    local function drawScrollBar()
        local tab = currentTab()
        local options = tab.options
        local topIndex = tab.topIndex
        local trackX = listRight
        local trackTop = listTop
        local trackBottom = listBottom
        local trackHeight = trackBottom - trackTop + 1

        for y = trackTop, trackBottom do
            writeAt(trackX, y, colors.gray, colors.gray, " ")
        end

        if #options <= listHeight then
            return
        end

        local maxTop = math.max(1, #options - listHeight + 1)
        local handleHeight = math.max(1, math.floor((listHeight * trackHeight) / #options))
        local handleRange = trackHeight - handleHeight
        local handleOffset = 0
        if maxTop > 1 and handleRange > 0 then
            handleOffset = math.floor(((topIndex - 1) * handleRange) / (maxTop - 1))
        end
        local handleTop = trackTop + handleOffset
        local handleBottom = handleTop + handleHeight - 1
        for y = handleTop, handleBottom do
            writeAt(trackX, y, colors.lightGray, colors.lightGray, " ")
        end
    end

    local function drawList()
        local tab = currentTab()
        local options = tab.options
        local selected = tab.selected
        local topIndex = tab.topIndex
        for row = 0, listHeight - 1 do
            local y = listTop + row
            local optionIndex = topIndex + row
            local option = options[optionIndex]
            local isSelected = optionIndex == selected
            local bg = isSelected and colors.blue or colors.black
            local fg = isSelected and colors.white or colors.lightGray
            writeAt(listLeft, y, fg, bg, string.rep(" ", contentRight - listLeft + 1))
            if option then
                local text = ellipsize(option.label, contentRight - listLeft - 1)
                writeAt(listLeft + 1, y, fg, bg, text)
            end
        end
        drawScrollBar()
    end

    local function drawButton()
        local bg = customHovered and colors.orange or colors.gray
        local fg = customHovered and colors.black or colors.white
        writeAt(buttonX, buttonY, fg, bg, customLabel)
    end

    local function drawExitButton()
        local bg = exitHovered and colors.red or colors.gray
        local fg = colors.white
        writeAt(exitButtonX, buttonY, fg, bg, exitLabel)
    end

    local function drawCustomPrompt()
        local boxWidth = clamp(44, 30, math.max(30, width - 4))
        local boxHeight = 9
        local x1 = math.floor((width - boxWidth) / 2) + 1
        local y1 = math.floor((height - boxHeight) / 2) + 1
        local x2 = x1 + boxWidth - 1
        local y2 = y1 + boxHeight - 1

        for y = y1, y2 do
            writeAt(x1, y, colors.white, colors.gray, string.rep(" ", boxWidth))
        end

        writeAt(x1 + 2, y1 + 1, colors.black, colors.lightGray, "Custom version")
        writeAt(x1 + 2, y1 + 3, colors.black, colors.gray, "Git ref (branch or tag):")

        local inputX = x1 + 2
        local inputY = y1 + 4
        local inputW = boxWidth - 4
        local visibleW = math.max(1, inputW - 2)
        local startIdx = clamp(customCursor - visibleW + 1, 1, math.max(1, #customInput + 1))
        local shown = customInput:sub(startIdx, startIdx + visibleW - 1)
        shown = shown .. string.rep(" ", visibleW - #shown)
        writeAt(inputX, inputY, colors.black, colors.white, " " .. shown)
        writeAt(inputX + inputW - 1, inputY, colors.black, colors.white, " ")
        customHitboxes.input = { x1 = inputX, x2 = inputX + inputW - 1, y = inputY, start = startIdx }

        local cancelText = " Cancel "
        local okText = " OK "
        local cancelX = x1 + boxWidth - #cancelText - #okText - 4
        local okX = x1 + boxWidth - #okText - 2
        local buttonYLocal = y1 + boxHeight - 2
        writeAt(cancelX, buttonYLocal, colors.white, colors.black, cancelText)
        writeAt(okX, buttonYLocal, colors.white, colors.blue, okText)
        customHitboxes.cancel = { x1 = cancelX, x2 = cancelX + #cancelText - 1, y = buttonYLocal }
        customHitboxes.ok = { x1 = okX, x2 = okX + #okText - 1, y = buttonYLocal }

        if customError and customError ~= "" then
            writeAt(x1 + 2, y2 - 1, colors.red, colors.gray, ellipsize(customError, boxWidth - 4))
        end

        local cursorX = inputX + 1 + clamp(customCursor - startIdx, 0, visibleW - 1)
        term.setTextColor(colors.blue)
        term.setBackgroundColor(colors.white)
        term.setCursorPos(cursorX, inputY)
        term.setCursorBlink(true)
    end

    local function render()
        term.setCursorBlink(false)
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.white)
        term.clear()

        clearLine(1, colors.black)
        writeAt(2, 1, colors.cyan, colors.black, "ComputerCraft Browser Installer")
        drawTabs()
        clearLine(3, colors.black)
        writeAt(2, 3, colors.gray, colors.black, "Choose a version. Click entry or press Enter.")

        drawList()
        drawExitButton()
        drawButton()

        clearLine(height - 1, colors.black)
        if noteText and noteText ~= "" then
            writeAt(2, height - 1, colors.yellow, colors.black, ellipsize(noteText, width - 2))
        else
            writeAt(2, height - 1, colors.gray, colors.black, "Mouse wheel or arrow keys to scroll.")
        end

        if customMode then
            drawCustomPrompt()
        end
    end

    ensureVisible()
    render()

    while true do
        local event, a, b, c = os.pullEvent()
        if event == "mouse_scroll" then
            if customMode then
                -- Ignore scroll while modal is open.
            else
            local tab = currentTab()
            local direction = a
            local mouseY = c
            if mouseY >= listTop and mouseY <= listBottom then
                if direction > 0 then
                    tab.selected = clamp(tab.selected + 1, 1, #tab.options)
                else
                    tab.selected = clamp(tab.selected - 1, 1, #tab.options)
                end
                ensureVisible()
                render()
            end
            end
        elseif event == "mouse_click" then
            local mouseX = b
            local mouseY = c
            if customMode then
                if customHitboxes.cancel
                    and mouseY == customHitboxes.cancel.y
                    and mouseX >= customHitboxes.cancel.x1
                    and mouseX <= customHitboxes.cancel.x2 then
                    customMode = false
                    customError = nil
                    term.setCursorBlink(false)
                    render()
                elseif customHitboxes.ok
                    and mouseY == customHitboxes.ok.y
                    and mouseX >= customHitboxes.ok.x1
                    and mouseX <= customHitboxes.ok.x2 then
                    local value = trimWhitespace(customInput)
                    if value == "" then
                        customError = "Ref cannot be empty."
                        render()
                    else
                        restoreTerm()
                        return value
                    end
                elseif customHitboxes.input
                    and mouseY == customHitboxes.input.y
                    and mouseX >= customHitboxes.input.x1 + 1
                    and mouseX <= customHitboxes.input.x2 - 1 then
                    local clickedIndex = customHitboxes.input.start + (mouseX - (customHitboxes.input.x1 + 1))
                    customCursor = clamp(clickedIndex + 1, 1, #customInput + 1)
                    render()
                end
            else
            customHovered = mouseY == buttonY and mouseX >= buttonX and mouseX < (buttonX + buttonW)
            exitHovered = mouseY == buttonY and mouseX >= exitButtonX and mouseX < (exitButtonX + exitButtonW)
            if customHovered then
                customMode = true
                customInput = defaultRef or DEFAULT_REF
                customCursor = #customInput + 1
                customError = nil
                render()
                goto continue
            end
            if exitHovered then
                restoreTerm()
                return nil, "cancelled"
            end
            if mouseY == 2 then
                for i = 1, #tabHitboxes do
                    local hit = tabHitboxes[i]
                    if hit and mouseX >= hit.x1 and mouseX <= hit.x2 then
                        activeTab = i
                        ensureVisible()
                        render()
                        break
                    end
                end
            end
            if mouseY >= listTop and mouseY <= listBottom and mouseX >= listLeft and mouseX <= contentRight then
                local tab = currentTab()
                local clicked = tab.topIndex + (mouseY - listTop)
                if clicked >= 1 and clicked <= #tab.options then
                    tab.selected = clicked
                    ensureVisible()
                    render()
                    restoreTerm()
                    return tab.options[tab.selected].ref
                end
            end
            end
        elseif event == "mouse_move" then
            if not customMode then
                local mouseX = b
                local mouseY = c
                local hovered = mouseY == buttonY and mouseX >= buttonX and mouseX < (buttonX + buttonW)
                local exitNow = mouseY == buttonY and mouseX >= exitButtonX and mouseX < (exitButtonX + exitButtonW)
                if hovered ~= customHovered or exitNow ~= exitHovered then
                    customHovered = hovered
                    exitHovered = exitNow
                    drawExitButton()
                    drawButton()
                end
            end
        elseif event == "key" then
            if customMode then
                if a == keys.left then
                    customCursor = clamp(customCursor - 1, 1, #customInput + 1)
                    render()
                elseif a == keys.right then
                    customCursor = clamp(customCursor + 1, 1, #customInput + 1)
                    render()
                elseif a == keys.home then
                    customCursor = 1
                    render()
                elseif a == keys["end"] then
                    customCursor = #customInput + 1
                    render()
                elseif a == keys.backspace then
                    if customCursor > 1 then
                        customInput = customInput:sub(1, customCursor - 2) .. customInput:sub(customCursor)
                        customCursor = customCursor - 1
                        customError = nil
                        render()
                    end
                elseif a == keys.delete then
                    if customCursor <= #customInput then
                        customInput = customInput:sub(1, customCursor - 1) .. customInput:sub(customCursor + 1)
                        customError = nil
                        render()
                    end
                elseif a == keys.enter or a == keys.numPadEnter then
                    local value = trimWhitespace(customInput)
                    if value == "" then
                        customError = "Ref cannot be empty."
                        render()
                    else
                        restoreTerm()
                        return value
                    end
                elseif a == keys.escape then
                    customMode = false
                    customError = nil
                    term.setCursorBlink(false)
                    render()
                end
                goto continue
            end
            local tab = currentTab()
            local key = a
            if key == keys.up then
                tab.selected = clamp(tab.selected - 1, 1, #tab.options)
                ensureVisible()
                render()
            elseif key == keys.down then
                tab.selected = clamp(tab.selected + 1, 1, #tab.options)
                ensureVisible()
                render()
            elseif key == keys.pageUp then
                tab.selected = clamp(tab.selected - listHeight, 1, #tab.options)
                ensureVisible()
                render()
            elseif key == keys.pageDown then
                tab.selected = clamp(tab.selected + listHeight, 1, #tab.options)
                ensureVisible()
                render()
            elseif key == keys.left then
                activeTab = 1
                ensureVisible()
                render()
            elseif key == keys.right then
                activeTab = 2
                ensureVisible()
                render()
            elseif key == keys.enter or key == keys.numPadEnter then
                restoreTerm()
                return tab.options[tab.selected].ref
            elseif key == keys.q then
                restoreTerm()
                return nil, "cancelled"
            end
        elseif event == "char" then
            if customMode then
                customInput = customInput:sub(1, customCursor - 1) .. a .. customInput:sub(customCursor)
                customCursor = customCursor + 1
                customError = nil
                render()
            elseif a == "c" or a == "C" then
                customMode = true
                customInput = defaultRef or DEFAULT_REF
                customCursor = #customInput + 1
                customError = nil
                render()
            end
        elseif event == "terminate" then
            restoreTerm()
            error("Terminated", 0)
        elseif event == "term_resize" then
            width, height = term.getSize()
            listTop = 4
            listBottom = math.max(listTop, height - 4)
            listHeight = listBottom - listTop + 1
            listLeft = 2
            listRight = math.max(listLeft, width - 2)
            contentRight = math.max(listLeft, listRight - 2)
            buttonY = height
            buttonX = math.floor((width - #customLabel) / 2)
            exitButtonX = 2
            ensureVisible()
            render()
        end
        ::continue::
    end
end

local function chooseInstallDirectoryWizard(defaultDir)
    local oldBg = term.getBackgroundColor()
    local oldFg = term.getTextColor()
    local oldBlink = term.getCursorBlink and term.getCursorBlink() or false
    local width, height = term.getSize()
    local input = tostring(defaultDir or DEFAULT_INSTALL_DIR)
    local cursor = #input + 1
    local errText = nil
    local hitboxes = { input = nil, ok = nil, cancel = nil }

    local function restoreTerm()
        term.setCursorBlink(oldBlink)
        term.setBackgroundColor(oldBg)
        term.setTextColor(oldFg)
        term.clear()
        term.setCursorPos(1, 1)
    end

    local function trimWhitespace(value)
        return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
    end

    local function writeAt(x, y, fg, bg, text)
        term.setCursorPos(x, y)
        term.setTextColor(fg)
        term.setBackgroundColor(bg)
        write(text)
    end

    local function render()
        width, height = term.getSize()
        term.setCursorBlink(false)
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.white)
        term.clear()

        local boxWidth = clamp(50, 34, math.max(34, width - 4))
        local boxHeight = 11
        local x1 = math.floor((width - boxWidth) / 2) + 1
        local y1 = math.floor((height - boxHeight) / 2) + 1
        local y2 = y1 + boxHeight - 1

        for y = y1, y2 do
            writeAt(x1, y, colors.white, colors.gray, string.rep(" ", boxWidth))
        end

        writeAt(x1 + 2, y1 + 1, colors.black, colors.lightGray, "Install directory")
        writeAt(x1 + 2, y1 + 3, colors.black, colors.gray, "Where should Browser be installed?")

        local inputX = x1 + 2
        local inputY = y1 + 5
        local inputW = boxWidth - 4
        local visibleW = math.max(1, inputW - 2)
        local startIdx = clamp(cursor - visibleW + 1, 1, math.max(1, #input + 1))
        local shown = input:sub(startIdx, startIdx + visibleW - 1)
        shown = shown .. string.rep(" ", visibleW - #shown)
        writeAt(inputX, inputY, colors.black, colors.white, " " .. shown)
        writeAt(inputX + inputW - 1, inputY, colors.black, colors.white, " ")
        hitboxes.input = { x1 = inputX, x2 = inputX + inputW - 1, y = inputY, start = startIdx }

        local cancelText = " Cancel "
        local okText = " Continue "
        local cancelX = x1 + boxWidth - #cancelText - #okText - 4
        local okX = x1 + boxWidth - #okText - 2
        local buttonY = y2 - 2
        writeAt(cancelX, buttonY, colors.white, colors.black, cancelText)
        writeAt(okX, buttonY, colors.white, colors.blue, okText)
        hitboxes.cancel = { x1 = cancelX, x2 = cancelX + #cancelText - 1, y = buttonY }
        hitboxes.ok = { x1 = okX, x2 = okX + #okText - 1, y = buttonY }

        if errText and errText ~= "" then
            writeAt(x1 + 2, y2 - 1, colors.red, colors.gray, ellipsize(errText, boxWidth - 4))
        end

        local cursorX = inputX + 1 + clamp(cursor - startIdx, 0, visibleW - 1)
        term.setTextColor(colors.blue)
        term.setBackgroundColor(colors.white)
        term.setCursorPos(cursorX, inputY)
        term.setCursorBlink(true)
    end

    render()

    while true do
        local event, a, b, c = os.pullEvent()
        if event == "char" then
            input = input:sub(1, cursor - 1) .. a .. input:sub(cursor)
            cursor = cursor + 1
            errText = nil
            render()
        elseif event == "key" then
            if a == keys.left then
                cursor = clamp(cursor - 1, 1, #input + 1)
                render()
            elseif a == keys.right then
                cursor = clamp(cursor + 1, 1, #input + 1)
                render()
            elseif a == keys.home then
                cursor = 1
                render()
            elseif a == keys["end"] then
                cursor = #input + 1
                render()
            elseif a == keys.backspace then
                if cursor > 1 then
                    input = input:sub(1, cursor - 2) .. input:sub(cursor)
                    cursor = cursor - 1
                    errText = nil
                    render()
                end
            elseif a == keys.delete then
                if cursor <= #input then
                    input = input:sub(1, cursor - 1) .. input:sub(cursor + 1)
                    errText = nil
                    render()
                end
            elseif a == keys.enter or a == keys.numPadEnter then
                local value = trimWhitespace(input)
                if value == "" then
                    errText = "Install directory cannot be empty."
                    render()
                else
                    restoreTerm()
                    return value
                end
            elseif a == keys.escape then
                restoreTerm()
                return nil, "cancelled"
            end
        elseif event == "mouse_click" then
            local x = b
            local y = c
            if hitboxes.cancel and y == hitboxes.cancel.y and x >= hitboxes.cancel.x1 and x <= hitboxes.cancel.x2 then
                restoreTerm()
                return nil, "cancelled"
            elseif hitboxes.ok and y == hitboxes.ok.y and x >= hitboxes.ok.x1 and x <= hitboxes.ok.x2 then
                local value = trimWhitespace(input)
                if value == "" then
                    errText = "Install directory cannot be empty."
                    render()
                else
                    restoreTerm()
                    return value
                end
            elseif hitboxes.input and y == hitboxes.input.y and x >= hitboxes.input.x1 + 1 and x <= hitboxes.input.x2 - 1 then
                local clickedIndex = hitboxes.input.start + (x - (hitboxes.input.x1 + 1))
                cursor = clamp(clickedIndex + 1, 1, #input + 1)
                render()
            end
        elseif event == "term_resize" then
            render()
        elseif event == "terminate" then
            restoreTerm()
            error("Terminated", 0)
        end
    end
end

local function runInstallInFancyUi(owner, repo, ref, installDir)
    local oldBg = term.getBackgroundColor()
    local oldFg = term.getTextColor()
    local oldBlink = term.getCursorBlink and term.getCursorBlink() or false
    local width, height = term.getSize()
    local logs = {}
    local scrollOffset = 0
    local done = false
    local success = false
    local statusText = "Starting..."
    local statusColor = colors.lightGray
    local exitLabel = " Exit "
    local exitX = 2
    local footerY = height
    local logTop = 5
    local logBottom = math.max(logTop, height - 2)

    local function restoreTerm()
        term.setCursorBlink(oldBlink)
        term.setBackgroundColor(oldBg)
        term.setTextColor(oldFg)
        term.clear()
        term.setCursorPos(1, 1)
    end

    local function writeAt(x, y, fg, bg, text)
        term.setCursorPos(x, y)
        term.setTextColor(fg)
        term.setBackgroundColor(bg)
        write(text)
    end

    local function clearLine(y, bg)
        writeAt(1, y, colors.white, bg, string.rep(" ", width))
    end

    local function addLog(text, color)
        logs[#logs + 1] = {
            text = tostring(text or ""),
            color = color or colors.lightGray,
        }
        scrollOffset = 0
    end

    local function visibleLogRows()
        return math.max(1, logBottom - logTop + 1)
    end

    local function drawScrollbar()
        local trackX = width
        local rows = visibleLogRows()
        for y = logTop, logBottom do
            writeAt(trackX, y, colors.gray, colors.gray, " ")
        end
        if #logs <= rows then
            return
        end
        local maxOffset = math.max(0, #logs - rows)
        local topIndex = #logs - rows + 1 - scrollOffset
        topIndex = clamp(topIndex, 1, math.max(1, #logs - rows + 1))
        local handleH = math.max(1, math.floor((rows * rows) / #logs))
        local handleRange = rows - handleH
        local handleOffset = 0
        if maxOffset > 0 and handleRange > 0 then
            handleOffset = math.floor(((topIndex - 1) * handleRange) / maxOffset)
        end
        local handleTop = logTop + handleOffset
        for y = handleTop, handleTop + handleH - 1 do
            if y >= logTop and y <= logBottom then
                writeAt(trackX, y, colors.lightGray, colors.lightGray, " ")
            end
        end
    end

    local function render()
        width, height = term.getSize()
        footerY = height
        logTop = 5
        logBottom = math.max(logTop, height - 2)
        local rows = visibleLogRows()
        local maxOffset = math.max(0, #logs - rows)
        scrollOffset = clamp(scrollOffset, 0, maxOffset)

        term.setCursorBlink(false)
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.white)
        term.clear()

        clearLine(1, colors.black)
        writeAt(2, 1, colors.cyan, colors.black, "ComputerCraft Browser Installer")
        clearLine(2, colors.black)
        writeAt(2, 2, colors.lightGray, colors.black, "Version: " .. tostring(ref))
        clearLine(3, colors.black)
        writeAt(2, 3, colors.lightGray, colors.black, "Install dir: " .. tostring(installDir))
        clearLine(4, colors.black)
        writeAt(2, 4, statusColor, colors.black, ellipsize(statusText, width - 3))

        for y = logTop, logBottom do
            clearLine(y, colors.black)
        end

        local startIndex = math.max(1, #logs - rows + 1 - scrollOffset)
        local endIndex = math.min(#logs, startIndex + rows - 1)
        local y = logTop
        for i = startIndex, endIndex do
            local entry = logs[i]
            writeAt(2, y, entry.color, colors.black, ellipsize(entry.text, width - 4))
            y = y + 1
        end
        drawScrollbar()

        clearLine(footerY, colors.black)
        writeAt(exitX, footerY, colors.white, colors.gray, exitLabel)
        if done then
            writeAt(2 + #exitLabel + 2, footerY, colors.gray, colors.black, "Press Enter to close")
        else
            writeAt(2 + #exitLabel + 2, footerY, colors.gray, colors.black, "Installing...")
        end
    end

    local function fail(text)
        done = true
        success = false
        statusText = "Install failed"
        statusColor = colors.red
        addLog(text, colors.red)
        render()
    end

    render()
    local resolvedRef, resolvedErr = resolveRef(owner, repo, ref)
    if not resolvedRef then
        fail(tostring(resolvedErr))
    else
        ref = resolvedRef
        statusText = "Fetching repository tree..."
        statusColor = colors.lightGray
        addLog(("Resolving files from %s/%s (%s)"):format(owner, repo, ref), colors.lightGray)
        render()

        local fullTree, treeErr = fetchTree(owner, repo, ref)
        if not fullTree then
            fail("Failed to read repository tree: " .. tostring(treeErr))
        else
            local sourceRoot, sourceErr = pickSourceRoot(fullTree)
            if not sourceRoot then
                fail(tostring(sourceErr))
            else
                local ignoreMatcher, ignoreErr = buildCcignoreMatcher(owner, repo, ref, fullTree, sourceRoot)
                if ignoreErr and ignoreErr ~= "" then
                    addLog(ignoreErr, colors.yellow)
                end
                local files = listFilesFromTree(fullTree, sourceRoot, ignoreMatcher)
                local sourceLabel = sourceRoot == "" and "(repo root)" or sourceRoot
                if #files == 0 then
                    fail("No installable files found in " .. sourceLabel)
                else
                    statusText = ("Installing %d files..."):format(#files)
                    statusColor = colors.lightBlue
                    addLog(("Installing %d files from %s"):format(#files, sourceLabel), colors.lightBlue)
                    render()

                    for i = 1, #files do
                        local item = files[i]
                        local rawUrl = ("https://raw.githubusercontent.com/%s/%s/%s/%s")
                            :format(owner, repo, ref, item.repoPath)
                        local targetPath = fs.combine(installDir, item.relative)
                        local step = ("[%d/%d] %s"):format(i, #files, item.relative)
                        statusText = step
                        addLog(step, colors.lightGray)
                        render()

                        local content, downloadErr = httpGetText(rawUrl)
                        if not content then
                            fail("Download failed: " .. tostring(downloadErr))
                            break
                        end

                        local neededBytes = #content
                        local freeBytes = getFreeSpaceBytes(installDir)
                        if freeBytes and freeBytes < neededBytes then
                            fail(
                                ("Out of space before writing %s (need %s, free %s).")
                                    :format(item.relative, formatBytes(neededBytes), formatBytes(freeBytes))
                            )
                            break
                        end

                        local ok, writeErr = writeFile(targetPath, content)
                        if not ok then
                            if isOutOfSpaceError(writeErr) then
                                local remaining = getFreeSpaceBytes(installDir)
                                fail(
                                    ("Out of space while writing %s (need %s, free %s).")
                                        :format(
                                            item.relative,
                                            formatBytes(neededBytes),
                                            formatBytes(remaining)
                                        )
                                )
                            else
                                fail(("Write failed for %s: %s"):format(targetPath, tostring(writeErr)))
                            end
                            break
                        end

                        addLog("  ok", colors.lime)
                        render()
                    end

                    if not done then
                        done = true
                        success = true
                        statusText = "Install complete"
                        statusColor = colors.lime
                        addLog("Run with: " .. fs.combine(installDir, "run.lua"), colors.cyan)
                        render()
                    end
                end
            end
        end
    end

    while true do
        local event, a, b, c = os.pullEvent()
        if event == "mouse_scroll" then
            local rows = visibleLogRows()
            local maxOffset = math.max(0, #logs - rows)
            if maxOffset > 0 then
                if a > 0 then
                    scrollOffset = clamp(scrollOffset + 1, 0, maxOffset)
                else
                    scrollOffset = clamp(scrollOffset - 1, 0, maxOffset)
                end
                render()
            end
        elseif event == "mouse_click" then
            local x = b
            local y = c
            if y == footerY and x >= exitX and x < (exitX + #exitLabel) then
                restoreTerm()
                return success and "success" or "failed"
            end
        elseif event == "key" then
            if a == keys.enter or a == keys.numPadEnter or a == keys.q or a == keys.escape then
                restoreTerm()
                return success and "success" or "failed"
            end
        elseif event == "term_resize" then
            render()
        elseif event == "terminate" then
            restoreTerm()
            error("Terminated", 0)
        end
    end
end

local function main(...)
    if not http then
        printError("HTTP API is not available. Enable it in CC:Tweaked config.")
        return
    end

    local args = { ... }
    local owner = args[1]
    local repo = args[2]
    local installDir = args[3] or DEFAULT_INSTALL_DIR
    local ref = args[4]

    owner = owner or DEFAULT_REPO_OWNER
    repo = repo or DEFAULT_REPO_NAME
    if not ref or ref == "" then
        local releases, branches, noteText = buildVersionOptions(owner, repo, DEFAULT_REF)
        local pickResult, pickStatus = chooseVersionWizard(releases, branches, DEFAULT_REF, noteText)
        if pickStatus == "cancelled" then
            return
        end
        ref = pickResult
    end
    local pickedInstallDir, dirStatus = chooseInstallDirectoryWizard(installDir)
    if dirStatus == "cancelled" or not pickedInstallDir then
        return
    end
    installDir = pickedInstallDir

    if not owner or owner == "" or not repo or repo == "" or not ref or ref == "" then
        return
    end

    runInstallInFancyUi(owner, repo, ref, installDir)
end

main(...)

