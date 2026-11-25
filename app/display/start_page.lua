local shortcuts = {
    { label = "Favorites", url = "about:favorites", icon = "bookmark" },
    { label = "History", url = "about:history", icon = "clock" },
    { label = "Settings", url = "about:settings", icon = "settings" },
    { label = "Help", url = "about:help", icon = "help" },
}

return function(screen, theme, width, height, cellWidth, rowHeight, top, addressFocused)
    local cells = math.floor(width / cellWidth)
    local inset = math.max(2, math.floor((cells - 54) / 2)) * cellWidth
    local usable = width - inset * 2
    local compact = cells < 43
    local contentHeight = height - top
    local tight = contentHeight < rowHeight * 10
    local gapY = tight and 5 or rowHeight
    local y = top + (tight and math.min(9, math.max(3, math.floor(contentHeight / 12)))
        or math.max(rowHeight, math.floor((contentHeight - rowHeight * 8) / 3)))
    local titleSize = compact and 24 or 32
    if tight then titleSize = math.min(titleSize, math.max(10, math.floor(contentHeight * 0.22))) end
    local title = "CC Browser"
    local addressSize = tight and rowHeight + 6 or rowHeight * 2
    local actions = {}

    local function label(x, posY, text, size, color, bold)
        screen.text(x, posY, text, { size = size, color = color, bold = bold })
    end

    local function shape(name, x, posY, color)
        if name == "bookmark" then
            screen.polyline({{x - 3, posY + 4}, {x - 3, posY - 4}, {x + 3, posY - 4},
                {x + 3, posY + 4}, {x, posY + 1}, {x - 3, posY + 4}}, color)
        elseif name == "clock" then
            screen.circle(x, posY, 4, color)
            screen.line(x, posY - 2, x, posY, color)
            screen.line(x, posY, x + 2, posY + 1, color)
        elseif name == "settings" then
            screen.polygon({{x, posY - 4}, {x + 4, posY - 2}, {x + 4, posY + 2},
                {x, posY + 4}, {x - 4, posY + 2}, {x - 4, posY - 2}}, color)
            screen.pixel(x, posY, color)
        else
            screen.circle(x, posY, 4, color)
            screen.polyline({{x - 1, posY - 1}, {x, posY - 2}, {x + 1, posY - 1}, {x, posY}}, color)
            screen.pixel(x, posY + 2, color)
        end
    end

    screen.fillRect(0, top, width, contentHeight, theme.field)
    screen.fillRect(0, top, width, 1, theme.edge)
    local titleHeight = titleSize + 3
    if screen.measureText then
        while titleSize > rowHeight and screen.measureText(title, {size=titleSize, bold=true}) > usable-cellWidth-2 do
            titleSize = titleSize-1
        end
        titleHeight = titleSize+3
    end
    screen.fillRect(inset, y + 2, 3, titleSize - 2, theme.accent)
    label(inset + cellWidth + 2, y, title, titleSize, theme.ink, true)

    y = y + titleHeight + gapY
    theme.round(screen, inset, y, usable, addressSize, addressFocused and theme.edge or theme.tab)
    theme.round(screen, inset + 1, y + 1, usable - 2, addressSize - 2, theme.toolbar)
    local lensX, lensY = inset + 10, y + math.floor(addressSize / 2) - 2
    screen.circle(lensX, lensY, 3, theme.accent)
    screen.line(lensX + 2, lensY + 2, lensX + 5, lensY + 5, theme.accent)
    local prompt = width < 205 and "Address" or compact and "Enter an address" or "Enter an address or file path"
    label(inset + 21, y + math.floor((addressSize - rowHeight) / 2), prompt,
        rowHeight, theme.secondary)
    actions[#actions + 1] = { x = inset, y = y, w = usable, h = addressSize, target = "address" }

    y = y + addressSize + gapY
    local perRow = compact and 2 or 4
    local gap = cellWidth
    local cardWidth = math.floor((usable - gap * (perRow - 1)) / perRow)
    local cardHeight = tight and rowHeight or rowHeight + 6
    for index, shortcut in ipairs(shortcuts) do
        local x = inset + ((index - 1) % perRow) * (cardWidth + gap)
        local cardY = y + math.floor((index - 1) / perRow) * (cardHeight + 4)
        if cardY + cardHeight <= height then
            theme.round(screen, x, cardY, cardWidth, cardHeight, theme.tab)
            shape(shortcut.icon, x + 8, cardY + math.floor(cardHeight / 2), theme.accent)
            local labelY = cardY + math.floor((cardHeight - rowHeight) / 2)
            local size = math.max(1, math.min(rowHeight, math.floor((cardWidth - 19) * 1.5 / #shortcut.label)))
            screen.setClip(x + 16, cardY, cardWidth - 17, cardHeight)
            label(x + 16, labelY, shortcut.label, size, theme.ink)
            screen.resetClip()
            actions[#actions + 1] = { x = x, y = cardY, w = cardWidth, h = cardHeight, target = shortcut.url }
        end
    end
    return actions
end
