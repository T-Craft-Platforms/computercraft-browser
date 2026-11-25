local palette = {
    frame = {16, 0x101923}, toolbar = {17, 0x1B2935},
    tab = {18, 0x243744}, active = {19, 0x304758},
    edge = {20, 0x456174}, ink = {21, 0xEFF6FA},
    secondary = {22, 0xA7C0CF}, muted = {23, 0x708B9D},
    accent = {24, 0x7EE0D0}, close = {25, 0xF3A59C},
    field = {26, 0x0F1B25}, selection = {27, 0x276076},
    track = {28, 0x1E303D}, thumb = {29, 0x729BB0},
}

local chrome = {}
for name, entry in pairs(palette) do chrome[name] = entry[1] end

function chrome.applyPalette(screen)
    for _, entry in pairs(palette) do screen.setPaletteColor(entry[1], entry[2]) end
end

local function round(surface, x, y, width, height, color)
    local radius = math.min(3, math.floor((width - 1) / 2), math.floor((height - 1) / 2))
    if radius < 1 then
        surface.fillRect(x, y, width, height, color)
        return
    end
    surface.fillRect(x + radius, y, width - radius * 2, height, color)
    surface.fillRect(x, y + radius, width, height - radius * 2, color)
    for _, dx in ipairs({radius, width - radius - 1}) do
        for _, dy in ipairs({radius, height - radius - 1}) do
            surface.fillCircle(x + dx, y + dy, radius, color)
        end
    end
end
chrome.round = round

local function icon(surface, name, x, y, color)
    local function line(a, b, c, d)
        surface.line(x + a, y + b, x + c, y + d, color)
    end
    if name == "close" then
        line(-2, -2, 2, 2)
        line(-2, 2, 2, -2)
    elseif name == "back" or name == "forward" then
        local sign = name == "back" and 1 or -1
        line(-3, 0, 3, 0)
        line(-3 * sign, 0, 0, -3)
        line(-3 * sign, 0, 0, 3)
    elseif name == "reload" then
        surface.polyline({
            {x + 3, y}, {x + 3, y + 2}, {x + 1, y + 4}, {x - 2, y + 4},
            {x - 4, y + 2}, {x - 4, y - 1}, {x - 2, y - 3}, {x + 1, y - 3}, {x + 3, y - 1},
        }, color)
        line(3, -4, 3, -1)
        line(0, -1, 3, -1)
    elseif name == "new" then
        line(-3, 0, 3, 0)
        line(0, -3, 0, 3)
    elseif name == "site" then
        surface.circle(x, y, 3, color)
        line(-3, 0, 3, 0)
        line(0, -3, 0, 3)
    elseif name == "menu" then
        for offset = -3, 3, 3 do surface.pixel(x + offset, y, color) end
    end
end

function chrome.draw(surface, width, cellWidth, rowHeight, fontSize, tabsText, url, urlBackground, state, encode)
    local ui = state.ui
    local active = state.tabs[state.activeTab]
    local textPadding = math.floor((rowHeight - fontSize) / 2)
    local function left(region)
        return (region.x1 - 1) * cellWidth
    end
    local function regionWidth(region)
        return (region.x2 - region.x1 + 1) * cellWidth
    end
    local function button(region, name, color)
        local size = regionWidth(region)
        if size <= 0 then return end
        local top = (region.y - 1) * rowHeight
        icon(surface, name, left(region) + math.floor(size / 2), top + math.floor(rowHeight / 2), color)
    end

    surface.fillRect(0, 0, width, rowHeight, chrome.frame)
    surface.fillRect(0, rowHeight, width, rowHeight, chrome.toolbar)
    surface.fillRect(0, rowHeight * 2 - 1, width, 1, chrome.edge)

    round(surface, 0, 1, cellWidth, rowHeight - 2, chrome.tab)
    button(ui.closeBrowser, "close", chrome.close)

    for _, region in ipairs(ui.tabs) do
        local selected = region.index == state.activeTab
        local x, size = left(region), regionWidth(region)
        local close = ui.tabClose[region.index]
        round(surface, x, 1, size - 1, rowHeight - 1, selected and chrome.active or chrome.tab)
        local endColumn = close and close.x1 - 1 or region.x2
        local label = tabsText:sub(region.x1, endColumn)
        surface.setClip(x, 0, size - (close and cellWidth or 1), rowHeight)
        surface.text(x, textPadding, encode(label), {
            size = fontSize, color = selected and chrome.ink or chrome.secondary,
        })
        surface.resetClip()
        if close then button(close, "close", selected and chrome.secondary or chrome.muted) end
        if selected and size >= 3 then surface.fillRect(x + 1, rowHeight - 1, size - 2, 1, chrome.accent) end
    end

    button(ui.newTab, "new", chrome.accent)
    button(ui.back, "back", active.historyIndex > 1 and chrome.ink or chrome.muted)
    button(ui.forward, "forward", active.historyIndex < #active.history and chrome.ink or chrome.muted)
    button(ui.reload, active.loading and "close" or "reload", active.loading and chrome.accent or chrome.ink)
    button(ui.menuButton, "menu", state.menuOpen and chrome.accent or chrome.ink)

    local size = regionWidth(ui.url)
    if size <= 0 then return end
    local x = left(ui.url)
    local fieldLeft = x - cellWidth
    round(surface, fieldLeft, rowHeight + 1, size + cellWidth - 1, rowHeight - 3,
        active.urlFocus and chrome.edge or chrome.field)
    if active.urlFocus then
        round(surface, fieldLeft + 1, rowHeight + 2, size + cellWidth - 3, rowHeight - 5, chrome.field)
    end
    icon(surface, "site", fieldLeft + math.floor(cellWidth / 2), rowHeight + math.floor(rowHeight / 2), chrome.secondary)
    surface.setClip(x, rowHeight + 2, size - 1, rowHeight - 4)
    local runs = {}
    local start = ui.url.x1
    while start <= ui.url.x2 do
        local color = urlBackground:sub(start, start)
        local finish = start
        while finish < ui.url.x2 and urlBackground:sub(finish + 1, finish + 1) == color do finish = finish + 1 end
        local run = { text = encode(url:sub(start, finish)), color = chrome.ink }
        if color == "b" then run.background = chrome.selection end
        if color == "0" then run.background, run.color = chrome.ink, chrome.field end
        if color == "5" then run.background, run.color = chrome.accent, chrome.field end
        runs[#runs + 1] = run
        start = finish + 1
    end
    if #runs > 0 then surface.richText(x, rowHeight + textPadding, runs, { size = fontSize }) end
    surface.resetClip()
end

return chrome
