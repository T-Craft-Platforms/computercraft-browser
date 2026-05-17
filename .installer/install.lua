local DEFAULT_REPO_OWNER = "%REPO_OWNER%"
local DEFAULT_REPO_NAME = "%REPO_NAME%"
local DEFAULT_REF = "%REPO_REF%"
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

local function isPlaceholder(value)
    return value == nil or value == "" or value:match("^%%.+%%$") ~= nil
end

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

local function shouldInstallRelativePath(relative)
    if relative == ".gitignore" or relative == "installer.lua" then
        return false
    end
    if relative == ".installer" or startsWith(relative, ".installer/") then
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

local function listFilesFromTree(tree, sourceRoot)
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
            if relative ~= "" and shouldInstallRelativePath(relative) then
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

    if not owner or owner == "" then
        owner = isPlaceholder(DEFAULT_REPO_OWNER) and nil or DEFAULT_REPO_OWNER
    end
    if not repo or repo == "" then
        repo = isPlaceholder(DEFAULT_REPO_NAME) and nil or DEFAULT_REPO_NAME
    end
    if not ref or ref == "" then
        ref = isPlaceholder(DEFAULT_REF) and nil or DEFAULT_REF
    end

    owner = owner or ask("GitHub owner")
    repo = repo or ask("Repository name")
    ref = ref or ask("Git ref (branch or tag)", "main")
    installDir = ask("Install directory", installDir)

    if not owner or owner == "" or not repo or repo == "" or not ref or ref == "" then
        printError("Owner, repository, and Git ref are required.")
        return
    end

    print(("Fetching file tree from %s/%s (%s)..."):format(owner, repo, ref))
    local fullTree, treeErr = fetchTree(owner, repo, ref)
    if not fullTree then
        printError("Failed to read repository tree:")
        printError(treeErr)
        return
    end

    local sourceRoot, sourceErr = pickSourceRoot(fullTree)
    if not sourceRoot then
        printError(sourceErr)
        return
    end

    local files = listFilesFromTree(fullTree, sourceRoot)
    local sourceLabel = sourceRoot == "" and "(repo root)" or sourceRoot

    if #files == 0 then
        printError("No installable files found in " .. sourceLabel)
        return
    end

    print(("Installing %d files from %s into %s"):format(#files, sourceLabel, installDir))
    for i = 1, #files do
        local item = files[i]
        local rawUrl = ("https://raw.githubusercontent.com/%s/%s/%s/%s")
            :format(owner, repo, ref, item.repoPath)
        local targetPath = fs.combine(installDir, item.relative)

        write(("[%d/%d] %s ... "):format(i, #files, item.relative))
        local content, downloadErr = httpGetText(rawUrl)
        if not content then
            print("failed")
            printError(downloadErr)
            return
        end

        local ok, writeErr = writeFile(targetPath, content)
        if not ok then
            print("failed")
            printError(("Could not write %s: %s"):format(targetPath, tostring(writeErr)))
            return
        end
        print("ok")
    end

    print("")
    print("Install complete.")
    print("Run with:")
    print(fs.combine(installDir, "run.lua"))
end

main(...)

