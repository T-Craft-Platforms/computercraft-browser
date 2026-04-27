local function printerSupportsApi(printerDevice)
    if type(printerDevice) ~= "table" then
        return false, "Printer peripheral unavailable"
    end
    if type(printerDevice.newPage) ~= "function"
        or type(printerDevice.endPage) ~= "function"
        or type(printerDevice.setCursorPos) ~= "function"
        or type(printerDevice.write) ~= "function" then
        return false, "Selected peripheral does not support printer API"
    end
    return true, nil
end

local function printerPageSize(printerDevice)
    local pageWidth = 25
    local pageHeight = 21
    if type(printerDevice.getPageSize) ~= "function" then
        return pageWidth, pageHeight
    end
    local okSize, width, height = pcall(printerDevice.getPageSize)
    if not (okSize and tonumber(width) and tonumber(height)) then
        return pageWidth, pageHeight
    end
    return math.max(1, math.floor(tonumber(width))), math.max(1, math.floor(tonumber(height)))
end

local function printerBeginPage(printerDevice, pageTitle, pagesPrinted)
    local okNewPage, opened = pcall(printerDevice.newPage)
    if not okNewPage or opened == false then
        return false, "Printer is out of paper/ink or busy", pagesPrinted
    end
    local nextCount = pagesPrinted + 1
    if type(printerDevice.setPageTitle) == "function" and tostring(pageTitle or "") ~= "" then
        pcall(printerDevice.setPageTitle, tostring(pageTitle))
    end
    return true, nil, nextCount
end

local function printerEndPage(printerDevice, errorMessage)
    local okEndPage, ended = pcall(printerDevice.endPage)
    if not okEndPage or ended == false then
        return false, errorMessage
    end
    return true, nil
end

local function printerWriteChunk(printerDevice, row, chunk)
    if not pcall(printerDevice.setCursorPos, 1, row) then
        return false, "Printer cursor positioning failed"
    end
    local okWrite, writeErr = pcall(printerDevice.write, tostring(chunk or ""))
    if not okWrite then
        return false, "Printer write failed: " .. tostring(writeErr)
    end
    return true, nil
end

local function createPrinting()
    local api = {}

    function api.printLinesToPeripheral(printerDevice, lines, pageTitle, wrapPrintLine)
        local supported, supportedErr = printerSupportsApi(printerDevice)
        if not supported then
            return false, supportedErr
        end
        if type(wrapPrintLine) ~= "function" then
            return false, "Printer line wrapper unavailable"
        end

        local pageWidth, pageHeight = printerPageSize(printerDevice)
        local pagesPrinted = 0
        local okBegin, beginErr
        okBegin, beginErr, pagesPrinted = printerBeginPage(printerDevice, pageTitle, pagesPrinted)
        if not okBegin then
            return false, beginErr, pagesPrinted
        end

        local row = 1
        for _, line in ipairs(lines or {}) do
            for _, chunk in ipairs(wrapPrintLine(line, pageWidth)) do
                if row > pageHeight then
                    local okEnd, endErr = printerEndPage(printerDevice, "Could not finish printer page")
                    if not okEnd then
                        return false, endErr, pagesPrinted
                    end
                    local okNext, nextErr
                    okNext, nextErr, pagesPrinted = printerBeginPage(printerDevice, pageTitle, pagesPrinted)
                    if not okNext then
                        return false, nextErr, pagesPrinted
                    end
                    row = 1
                end

                local okWrite, writeErr = printerWriteChunk(printerDevice, row, chunk)
                if not okWrite then
                    return false, writeErr, pagesPrinted
                end
                row = row + 1
            end
        end

        local okFinalize, finalizeErr = printerEndPage(printerDevice, "Could not finalize printer job")
        if not okFinalize then
            return false, finalizeErr, pagesPrinted
        end
        return true, nil, pagesPrinted
    end

    return api
end

return createPrinting
