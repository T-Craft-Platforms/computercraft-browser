function loadDocumentWithAbort(tab, normalized, allowFallback, requestOptions)
    if not parallel or not parallel.waitForAny then
        local body, finalUrl, headers, err = fetchTextResource(normalized, allowFallback, requestOptions)
        if not body then
            finalUrl = normalized
            body = makeErrorPage(finalUrl, err or "Unknown error")
            headers = { ["Content-Type"] = "text/html" }
        end

        local contentType = getHeader(headers, "Content-Type") or ""
        if not looksLikeHtml(body, contentType) then
            body = "<html><body><pre>" .. escapeHtml(body) .. "</pre></body></html>"
        end
        local aboutUpdateIntervalMs = parseAboutUpdateIntervalMs(headers)
        local settingsStickyStatus = parseSettingsStatusMessage(headers, finalUrl or normalized)

        return {
            finalUrl = finalUrl,
            document = buildDocument(body, finalUrl),
            aboutUpdateIntervalMs = aboutUpdateIntervalMs,
            settingsStickyStatus = settingsStickyStatus,
        }, false
    end

    local result = nil
    local done = false
    local aborted = false

    local function loadTask()
        local ok, errMsg = pcall(function()
            local body, finalUrl, headers, err = fetchTextResource(normalized, allowFallback, requestOptions)
            if not body then
                finalUrl = normalized
                body = makeErrorPage(finalUrl, err or "Unknown error")
                headers = { ["Content-Type"] = "text/html" }
            end

            local contentType = getHeader(headers, "Content-Type") or ""
            if not looksLikeHtml(body, contentType) then
                body = "<html><body><pre>" .. escapeHtml(body) .. "</pre></body></html>"
            end
            local aboutUpdateIntervalMs = parseAboutUpdateIntervalMs(headers)
            local settingsStickyStatus = parseSettingsStatusMessage(headers, finalUrl or normalized)

            result = {
                finalUrl = finalUrl,
                document = buildDocument(body, finalUrl),
                aboutUpdateIntervalMs = aboutUpdateIntervalMs,
                settingsStickyStatus = settingsStickyStatus,
            }
        end)

        if not ok then
            local safeError = tostring(errMsg)
            log("document load task failed: " .. tostring(normalized) .. " (" .. safeError .. ")", LogLevel.error)
            local finalUrl = normalized
            local body = makeErrorPage(finalUrl, safeError)
            result = {
                finalUrl = finalUrl,
                document = buildDocument(body, finalUrl),
            }
        end

        done = true
    end

    local function watchTask()
        while not done do
            local event = { os.pullEvent() }
            local name = event[1]
            if name == "mouse_click" then
                local x = event[3]
                local y = event[4]
                if tab == activeTab() and hitRegion(x, y, state.ui.reload) then
                    aborted = true
                    return
                end
            elseif name == "key" then
                if event[2] == keys.escape then
                    aborted = true
                    return
                end
            elseif name == "timer" then
                if state.animationTimer and event[2] == state.animationTimer then
                    state.animationTimer = nil
                    if scheduleAnimationTick then
                        scheduleAnimationTick()
                    end
                    draw()
                end
            elseif name == "term_resize" then
                rerenderAllTabs()
                draw()
            end
        end
    end

    parallel.waitForAny(loadTask, watchTask)
    if scheduleAnimationTick then
        scheduleAnimationTick()
    end
    return result, aborted
end

function isLuaUrl(url)
    local raw = tostring(url or "")
    local stripped = raw:gsub("[?#].*$", "")
    if stripped:lower():match("%.lua$") ~= nil then
        return true
    end
    if startsWith(stripped:lower(), "about:") then
        local pageName = stripped:match("^about:([^/?#]+)") or ""
        if pageName ~= "" then
            local aboutLuaPath = fs.combine(fs.combine(SCRIPT_DIR, "about-pages"), pageName .. ".lua")
            return fs.exists(aboutLuaPath) and not fs.isDir(aboutLuaPath)
        end
    end
    return false
end

function isMidiUrl(url)
    local raw = tostring(url or "")
    local stripped = raw:gsub("[?#].*$", ""):lower()
    return stripped:match("%.mid$") ~= nil or stripped:match("%.midi$") ~= nil
end

local MIDI_DEFAULT_TEMPO_US_PER_QUARTER = 500000
local MIDI_DEFAULT_VOLUME = 1.0

local MIDI_INSTRUMENT_FAMILY = {
    "harp",
    "bell",
    "guitar",
    "guitar",
    "bass",
    "chime",
    "flute",
    "flute",
    "bit",
    "bit",
    "xylophone",
    "xylophone",
    "banjo",
    "didgeridoo",
    "pling",
    "iron_xylophone",
}

local function midiClamp(value, minValue, maxValue)
    if value < minValue then
        return minValue
    end
    if value > maxValue then
        return maxValue
    end
    return value
end

local function midiTrackNameFromUrl(url)
    local stripped = tostring(url or ""):gsub("[?#].*$", "")
    local name = stripped:match("([^/\\]+)$")
    if not name or name == "" then
        return stripped ~= "" and stripped or "MIDI"
    end
    return name
end

local function midiFormatSeconds(rawSeconds)
    local seconds = math.max(0, tonumber(rawSeconds) or 0)
    local whole = math.floor(seconds + 0.5)
    local mm = math.floor(whole / 60)
    local ss = whole % 60
    return ("%02d:%02d"):format(mm, ss)
end

local function midiReadU16BE(data, pos, limit)
    if (pos + 1) > limit then
        return nil, pos, "Unexpected end of MIDI data"
    end
    local b1, b2 = string.byte(data, pos, pos + 1)
    return (b1 * 256) + b2, pos + 2
end

local function midiReadU32BE(data, pos, limit)
    if (pos + 3) > limit then
        return nil, pos, "Unexpected end of MIDI data"
    end
    local b1, b2, b3, b4 = string.byte(data, pos, pos + 3)
    local value = (((b1 * 256) + b2) * 256 + b3) * 256 + b4
    return value, pos + 4
end

local function midiReadVarLen(data, pos, limit)
    local value = 0
    local bytesRead = 0
    while true do
        if pos > limit then
            return nil, pos, "Unexpected end of MIDI varlen"
        end
        local byte = string.byte(data, pos)
        pos = pos + 1
        bytesRead = bytesRead + 1
        value = (value * 128) + (byte % 128)
        if byte < 128 then
            return value, pos
        end
        if bytesRead >= 4 then
            return nil, pos, "Invalid MIDI varlen value"
        end
    end
end

local function midiReadChunk(data, pos, limit)
    if (pos + 7) > limit then
        return nil, nil, nil, pos, "Invalid MIDI chunk header"
    end
    local chunkType = data:sub(pos, pos + 3)
    pos = pos + 4
    local chunkLen, nextPos, lenErr = midiReadU32BE(data, pos, limit)
    if not chunkLen then
        return nil, nil, nil, pos, lenErr
    end
    pos = nextPos
    local chunkEnd = pos + chunkLen - 1
    if chunkEnd > limit then
        return nil, nil, nil, pos, "MIDI chunk exceeds data length"
    end
    local body = data:sub(pos, chunkEnd)
    return chunkType, body, chunkLen, chunkEnd + 1, nil
end

local function midiEventSortRank(kind)
    if kind == "tempo" then
        return 1
    end
    if kind == "program" then
        return 2
    end
    if kind == "note_off" then
        return 3
    end
    return 4
end

local function parseMidiTrack(trackData, trackIndex)
    local events = {}
    local pos = 1
    local limit = #trackData
    local absoluteTick = 0
    local runningStatus = nil

    while pos <= limit do
        local delta, nextPos, deltaErr = midiReadVarLen(trackData, pos, limit)
        if not delta then
            return nil, deltaErr
        end
        pos = nextPos
        absoluteTick = absoluteTick + delta
        if pos > limit then
            break
        end

        local statusByte = string.byte(trackData, pos)
        if statusByte >= 128 then
            pos = pos + 1
            if statusByte < 240 then
                runningStatus = statusByte
            end
        elseif runningStatus then
            statusByte = runningStatus
        else
            return nil, "MIDI running status missing"
        end

        if statusByte == 255 then
            if pos > limit then
                return nil, "Invalid MIDI meta event"
            end
            local metaType = string.byte(trackData, pos)
            pos = pos + 1
            local metaLen, metaPos, metaErr = midiReadVarLen(trackData, pos, limit)
            if not metaLen then
                return nil, metaErr
            end
            pos = metaPos
            if (pos + metaLen - 1) > limit then
                return nil, "MIDI meta event truncated"
            end
            local payloadStart = pos
            pos = pos + metaLen
            if metaType == 47 then
                break
            elseif metaType == 81 and metaLen == 3 then
                local b1, b2, b3 = string.byte(trackData, payloadStart, payloadStart + 2)
                local tempoUs = (b1 * 65536) + (b2 * 256) + b3
                events[#events + 1] = {
                    tick = absoluteTick,
                    kind = "tempo",
                    usPerQuarter = tempoUs,
                    track = trackIndex,
                }
            end
        elseif statusByte == 240 or statusByte == 247 then
            local sysLen, sysPos, sysErr = midiReadVarLen(trackData, pos, limit)
            if not sysLen then
                return nil, sysErr
            end
            pos = sysPos + sysLen
            if pos > (limit + 1) then
                return nil, "MIDI sysex event truncated"
            end
        else
            local eventType = math.floor(statusByte / 16)
            local channel = (statusByte % 16) + 1
            local dataLen = 0
            if eventType == 12 or eventType == 13 then
                dataLen = 1
            else
                dataLen = 2
            end
            if (pos + dataLen - 1) > limit then
                return nil, "MIDI channel event truncated"
            end

            local d1 = string.byte(trackData, pos)
            local d2 = dataLen == 2 and string.byte(trackData, pos + 1) or nil
            pos = pos + dataLen

            if eventType == 9 then
                local velocity = tonumber(d2) or 0
                if velocity > 0 then
                    events[#events + 1] = {
                        tick = absoluteTick,
                        kind = "note_on",
                        channel = channel,
                        note = tonumber(d1) or 0,
                        velocity = velocity,
                        track = trackIndex,
                    }
                else
                    events[#events + 1] = {
                        tick = absoluteTick,
                        kind = "note_off",
                        channel = channel,
                        note = tonumber(d1) or 0,
                        velocity = 0,
                        track = trackIndex,
                    }
                end
            elseif eventType == 8 then
                events[#events + 1] = {
                    tick = absoluteTick,
                    kind = "note_off",
                    channel = channel,
                    note = tonumber(d1) or 0,
                    velocity = tonumber(d2) or 0,
                    track = trackIndex,
                }
            elseif eventType == 12 then
                events[#events + 1] = {
                    tick = absoluteTick,
                    kind = "program",
                    channel = channel,
                    program = tonumber(d1) or 0,
                    track = trackIndex,
                }
            end
        end
    end

    return events, nil
end

function parseMidiData(data)
    local raw = tostring(data or "")
    if #raw < 14 then
        return nil, "MIDI data is too short"
    end

    local pos = 1
    local limit = #raw
    local headerType, headerBody, _, nextPos, headerErr = midiReadChunk(raw, pos, limit)
    if not headerType then
        return nil, headerErr
    end
    if headerType ~= "MThd" then
        return nil, "Invalid MIDI header chunk"
    end
    if #headerBody < 6 then
        return nil, "Invalid MIDI header length"
    end
    local formatType = select(1, midiReadU16BE(headerBody, 1, #headerBody))
    local trackCount = select(1, midiReadU16BE(headerBody, 3, #headerBody))
    local division = select(1, midiReadU16BE(headerBody, 5, #headerBody))
    if not formatType or not trackCount or not division then
        return nil, "Invalid MIDI header payload"
    end
    if division <= 0 or division >= 32768 then
        return nil, "Unsupported MIDI time division"
    end
    pos = nextPos

    local events = {}
    local parsedTracks = 0
    while parsedTracks < trackCount and pos <= limit do
        local chunkType, chunkBody, _, chunkNextPos, chunkErr = midiReadChunk(raw, pos, limit)
        if not chunkType then
            return nil, chunkErr
        end
        pos = chunkNextPos
        if chunkType == "MTrk" then
            parsedTracks = parsedTracks + 1
            local trackEvents, trackErr = parseMidiTrack(chunkBody, parsedTracks)
            if not trackEvents then
                return nil, trackErr
            end
            for i = 1, #trackEvents do
                events[#events + 1] = trackEvents[i]
            end
        end
    end

    table.sort(events, function(a, b)
        if a.tick ~= b.tick then
            return a.tick < b.tick
        end
        local ar = midiEventSortRank(a.kind)
        local br = midiEventSortRank(b.kind)
        if ar ~= br then
            return ar < br
        end
        if (a.track or 0) ~= (b.track or 0) then
            return (a.track or 0) < (b.track or 0)
        end
        return false
    end)

    local tempoUs = MIDI_DEFAULT_TEMPO_US_PER_QUARTER
    local secondsPerTick = (tempoUs / 1000000) / division
    local previousTick = 0
    local elapsedSeconds = 0
    for _, event in ipairs(events) do
        local deltaTicks = (event.tick or 0) - previousTick
        if deltaTicks > 0 then
            elapsedSeconds = elapsedSeconds + (deltaTicks * secondsPerTick)
            previousTick = event.tick or previousTick
        end
        event.timeSeconds = elapsedSeconds
        if event.kind == "tempo" and tonumber(event.usPerQuarter) and event.usPerQuarter > 0 then
            tempoUs = math.floor(event.usPerQuarter)
            secondsPerTick = (tempoUs / 1000000) / division
        end
    end

    local totalTicks = previousTick
    if #events > 0 and totalTicks <= 0 then
        totalTicks = events[#events].tick or 0
    end

    return {
        formatType = formatType,
        trackCount = trackCount,
        division = division,
        events = events,
        totalTicks = totalTicks,
        totalSeconds = elapsedSeconds,
        bytes = #raw,
    }, nil
end

local function midiProgramToInstrument(program)
    local index = math.floor((tonumber(program) or 0) / 8) + 1
    index = midiClamp(index, 1, #MIDI_INSTRUMENT_FAMILY)
    return MIDI_INSTRUMENT_FAMILY[index]
end

local function midiPercussionInstrument(note)
    local n = tonumber(note) or 0
    if n == 35 or n == 36 then
        return "basedrum"
    end
    if n == 38 or n == 40 then
        return "snare"
    end
    if n == 42 or n == 44 or n == 46 then
        return "hat"
    end
    if n == 56 or n == 75 then
        return "cow_bell"
    end
    return "basedrum"
end

local function midiNoteToPitch(note)
    local pitch = math.floor((tonumber(note) or 54) - 54)
    while pitch < 0 do
        pitch = pitch + 12
    end
    while pitch > 24 do
        pitch = pitch - 12
    end
    return midiClamp(pitch, 0, 24)
end

local function midiFindSpeaker()
    if not peripheral or type(peripheral.getNames) ~= "function" or type(peripheral.getType) ~= "function" then
        return nil, nil
    end
    local names = peripheral.getNames() or {}
    for _, name in ipairs(names) do
        if tostring(peripheral.getType(name) or ""):lower() == "speaker" then
            local wrapped = peripheral.wrap and peripheral.wrap(name) or nil
            if wrapped then
                return wrapped, tostring(name)
            end
        end
    end
    return nil, nil
end

function makeMidiPlaybackState(parsed, sourceUrl)
    local stateObject = {
        sourceUrl = tostring(sourceUrl or ""),
        fileName = midiTrackNameFromUrl(sourceUrl),
        parsed = parsed,
        mode = "stopped",
        statusMessage = "Ready",
        volume = MIDI_DEFAULT_VOLUME,
        positionSeconds = 0,
        positionTicks = 0,
        nextEventIndex = 1,
        tempoUsPerQuarter = MIDI_DEFAULT_TEMPO_US_PER_QUARTER,
        secondsPerTick = (MIDI_DEFAULT_TEMPO_US_PER_QUARTER / 1000000) / math.max(1, parsed.division or 480),
        lastWallClock = nil,
        channelPrograms = {},
        speakerConnected = false,
        speakerName = nil,
        finished = false,
    }
    for channel = 1, 16 do
        stateObject.channelPrograms[channel] = 0
    end
    return stateObject
end

function midiSeekToSeconds(midi, targetSeconds)
    local parsed = midi and midi.parsed or nil
    if not midi or not parsed then
        return false
    end
    local events = parsed.events or {}
    local clampedTarget = midiClamp(tonumber(targetSeconds) or 0, 0, tonumber(parsed.totalSeconds) or 0)
    local index = 1
    while index <= #events and (tonumber(events[index].timeSeconds) or 0) < clampedTarget do
        index = index + 1
    end

    midi.nextEventIndex = index
    midi.positionSeconds = clampedTarget
    midi.tempoUsPerQuarter = MIDI_DEFAULT_TEMPO_US_PER_QUARTER
    midi.secondsPerTick = (midi.tempoUsPerQuarter / 1000000) / math.max(1, parsed.division or 480)
    midi.positionTicks = 0
    for channel = 1, 16 do
        midi.channelPrograms[channel] = 0
    end

    local lastTempoSeconds = 0
    local lastTempoTick = 0
    for eventIndex = 1, (index - 1) do
        local event = events[eventIndex]
        if event then
            if event.kind == "program" and tonumber(event.channel) and tonumber(event.program) then
                midi.channelPrograms[event.channel] = midiClamp(math.floor(event.program), 0, 127)
            elseif event.kind == "tempo" and tonumber(event.usPerQuarter) and event.usPerQuarter > 0 then
                midi.tempoUsPerQuarter = math.floor(event.usPerQuarter)
                midi.secondsPerTick = (midi.tempoUsPerQuarter / 1000000) / math.max(1, parsed.division or 480)
                lastTempoSeconds = tonumber(event.timeSeconds) or lastTempoSeconds
                lastTempoTick = tonumber(event.tick) or lastTempoTick
            end
        end
    end

    local deltaSeconds = clampedTarget - lastTempoSeconds
    if deltaSeconds < 0 then
        deltaSeconds = 0
    end
    midi.positionTicks = lastTempoTick + (deltaSeconds / math.max(1e-9, midi.secondsPerTick))
    midi.lastWallClock = os.clock()
    midi.finished = clampedTarget >= ((tonumber(parsed.totalSeconds) or 0) - 1e-6)
    return true
end

function resetMidiPlaybackState(midi)
    if not midi or not midi.parsed then
        return false
    end
    midi.mode = "stopped"
    midi.statusMessage = "Stopped"
    midi.positionSeconds = 0
    midi.positionTicks = 0
    midi.nextEventIndex = 1
    midi.tempoUsPerQuarter = MIDI_DEFAULT_TEMPO_US_PER_QUARTER
    midi.secondsPerTick = (midi.tempoUsPerQuarter / 1000000) / math.max(1, midi.parsed.division or 480)
    midi.lastWallClock = nil
    midi.finished = false
    for channel = 1, 16 do
        midi.channelPrograms[channel] = 0
    end
    return true
end

local MIDI_ACTION_PREFIX = "ccbrowser-midi"

function makeMidiActionUrl(action, params)
    local parts = { "action=" .. urlEncode(tostring(action or "")) }
    for key, value in pairs(params or {}) do
        parts[#parts + 1] = urlEncode(tostring(key or "")) .. "=" .. urlEncode(tostring(value or ""))
    end
    return "#" .. MIDI_ACTION_PREFIX .. "?" .. table.concat(parts, "&")
end

function parseMidiActionUrl(url)
    local raw = tostring(url or "")
    local marker = "#" .. MIDI_ACTION_PREFIX
    local lowered = raw:lower()
    local markerPos = lowered:find(marker, 1, true)
    if not markerPos then
        return nil, {}
    end
    local remainder = raw:sub(markerPos + #marker)
    local query = ""
    if remainder:sub(1, 1) == "?" then
        query = remainder:sub(2)
    end
    local params = {}
    for token in query:gmatch("([^&]+)") do
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
    local action = trim(tostring(params.action or "")):lower()
    return action, params
end

function renderMidiPlayerHtml(sourceUrl, midi)
    local parsed = midi and midi.parsed or {}
    local currentSeconds = tonumber(midi and midi.positionSeconds or 0) or 0
    local totalSeconds = tonumber(parsed.totalSeconds or 0) or 0
    local progress = 0
    if totalSeconds > 0 then
        progress = (currentSeconds / totalSeconds) * 100
    end
    progress = midiClamp(progress, 0, 100)

    local speakerLine = midi and midi.speakerConnected
            and ("Connected: " .. tostring(midi.speakerName or "speaker"))
        or "No speaker connected. Connect a speaker peripheral to play MIDI."
    local statusLine = midi and tostring(midi.statusMessage or "Ready") or "Ready"
    local modeLine = midi and tostring(midi.mode or "stopped") or "stopped"

    local controls = table.concat({
        "<p>",
        "<a href=\"" .. escapeHtml(makeMidiActionUrl("before", { seconds = "10" })) .. "\">[Before -10s]</a> ",
        "<a href=\"" .. escapeHtml(makeMidiActionUrl("play", {})) .. "\">[Play]</a> ",
        "<a href=\"" .. escapeHtml(makeMidiActionUrl("pause", {})) .. "\">[Pause]</a> ",
        "<a href=\"" .. escapeHtml(makeMidiActionUrl("stop", {})) .. "\">[Stop]</a> ",
        "<a href=\"" .. escapeHtml(makeMidiActionUrl("skip", { seconds = "10" })) .. "\">[Skip +10s]</a>",
        "</p>",
        "<p>",
        "<a href=\"" .. escapeHtml(makeMidiActionUrl("seek_start", {})) .. "\">[Start]</a> ",
        "<a href=\"" .. escapeHtml(makeMidiActionUrl("before", { seconds = "30" })) .. "\">[-30s]</a> ",
        "<a href=\"" .. escapeHtml(makeMidiActionUrl("before", { seconds = "5" })) .. "\">[-5s]</a> ",
        "<a href=\"" .. escapeHtml(makeMidiActionUrl("skip", { seconds = "5" })) .. "\">[+5s]</a> ",
        "<a href=\"" .. escapeHtml(makeMidiActionUrl("skip", { seconds = "30" })) .. "\">[+30s]</a> ",
        "<a href=\"" .. escapeHtml(makeMidiActionUrl("seek_end", {})) .. "\">[End]</a>",
        "</p>",
        "<p>",
        "<a href=\"" .. escapeHtml(makeMidiActionUrl("volume_down", { delta = "0.1" })) .. "\">[Vol -]</a> ",
        "<a href=\"" .. escapeHtml(makeMidiActionUrl("volume_up", { delta = "0.1" })) .. "\">[Vol +]</a> ",
        "<a href=\"" .. escapeHtml(makeMidiActionUrl("volume_set", { value = "0.5" })) .. "\">[50%]</a> ",
        "<a href=\"" .. escapeHtml(makeMidiActionUrl("volume_set", { value = "1.0" })) .. "\">[100%]</a> ",
        "<a href=\"" .. escapeHtml(makeMidiActionUrl("volume_set", { value = "2.0" })) .. "\">[200%]</a> ",
        "<a href=\"" .. escapeHtml(makeMidiActionUrl("volume_set", { value = "3.0" })) .. "\">[300%]</a>",
        "</p>",
    })

    local body = {
        "<html><head><title>MIDI: " .. escapeHtml(midiTrackNameFromUrl(sourceUrl)) .. "</title></head><body>",
        "<h3>MIDI Player</h3>",
        "<p><b>File:</b> " .. escapeHtml(midiTrackNameFromUrl(sourceUrl)) .. "</p>",
        "<p><b>URL:</b> <code>" .. escapeHtml(sourceUrl) .. "</code></p>",
        "<p><b>Status:</b> " .. escapeHtml(statusLine) .. "</p>",
        "<p><b>Mode:</b> " .. escapeHtml(modeLine) .. "</p>",
        "<p><b>Speaker:</b> " .. escapeHtml(speakerLine) .. "</p>",
        "<p><b>Position:</b> "
            .. escapeHtml(midiFormatSeconds(currentSeconds))
            .. " / "
            .. escapeHtml(midiFormatSeconds(totalSeconds))
            .. " ("
            .. escapeHtml(("%d%%"):format(math.floor(progress + 0.5)))
            .. ")</p>",
        "<p><b>Volume:</b> " .. escapeHtml(("%.2f"):format(tonumber(midi and midi.volume or 1) or 1)) .. " (0.00 - 3.00)</p>",
        controls,
        "<hr>",
        "<p><b>Tracks:</b> " .. escapeHtml(tostring(parsed.trackCount or 0)) .. "</p>",
        "<p><b>MIDI format:</b> " .. escapeHtml(tostring(parsed.formatType or 0)) .. "</p>",
        "<p><b>Events:</b> " .. escapeHtml(tostring(parsed.events and #parsed.events or 0)) .. "</p>",
        "<p><b>Ticks per quarter:</b> " .. escapeHtml(tostring(parsed.division or 0)) .. "</p>",
        "<p><b>Size:</b> " .. escapeHtml(tostring(parsed.bytes or 0)) .. " bytes</p>",
        "<p><i>Instrument support is mapped to ComputerCraft speaker note-block instruments.</i></p>",
        "</body></html>",
    }
    return table.concat(body, "")
end

function renderMidiTab(target)
    if not target or not target.midi then
        return false
    end
    local sourceUrl = target.midi.sourceUrl or target.currentUrl or target.urlInput or "about:blank"
    target.document = buildDocument(renderMidiPlayerHtml(sourceUrl, target.midi), sourceUrl)
    target.currentUrl = sourceUrl
    target.urlInput = sourceUrl
    target.urlCursor = #target.urlInput + 1
    target.urlOffset = 0
    target.urlFocus = false
    clearUrlSelection(target)
    clearPageSelection(target)
    target.formState = {}
    target.formMeta = nil
    target.focusedFormControl = nil
    target.renderRevision = 0
    target.lastRenderSignature = nil
    target.aboutUpdateIntervalMs = nil
    target.settingsStickyStatus = nil
    target.pendingApplet = nil
    target.scroll = 0
    target.status = "MIDI: " .. tostring(target.midi.fileName or "")
    renderDocument(target)
    return true
end

function buildLuaSourceHtml(url, body, heading, statusLine, options)
    local opts = options or {}
    local executionBar = ""
    if opts.executable then
        local sandboxedUrl = makeAppletActionUrl("run", { mode = "sandboxed" })
        local systemUrl = makeAppletActionUrl("run", { mode = "system" })
        executionBar = "<div style=\"position:sticky;top:0;background-color:lightGray;color:black;padding:0 1;\">"
            .. "<p><b>This file is executable.</b></p>"
            .. "<p><a href=\"" .. escapeHtml(sandboxedUrl) .. "\">[Run Sandboxed]</a> "
            .. "<a href=\"" .. escapeHtml(systemUrl) .. "\" style=\"color:red;\"><b>[Run on System]</b></a></p>"
            .. "</div><hr>"
    end

    local statusSection = ""
    if statusLine and statusLine ~= "" then
        statusSection = "<p><i>" .. escapeHtml(statusLine) .. "</i></p><hr>"
    end

    return "<html><body>" .. executionBar
        .. "<h3>" .. escapeHtml(heading) .. "</h3>"
        .. statusSection
        .. "<pre>" .. escapeHtml(body) .. "</pre></body></html>"
end

local APPLET_ACTION_PREFIX = "ccbrowser-applet"

function makeAppletActionUrl(action, params)
    local parts = { "action=" .. urlEncode(tostring(action or "")) }
    for key, value in pairs(params or {}) do
        parts[#parts + 1] = urlEncode(tostring(key or "")) .. "=" .. urlEncode(tostring(value or ""))
    end
    return "#" .. APPLET_ACTION_PREFIX .. "?" .. table.concat(parts, "&")
end

function decodeQueryComponent(value)
    local text = tostring(value or "")
    text = text:gsub("+", " ")
    return core.decodeUrlPath(text)
end

function parseAppletActionUrl(url)
    local raw = tostring(url or "")
    local marker = "#" .. APPLET_ACTION_PREFIX
    local lowered = raw:lower()
    local markerPos = lowered:find(marker, 1, true)
    if not markerPos then
        return nil, {}
    end
    local remainder = raw:sub(markerPos + #marker)
    local query = ""
    if remainder:sub(1, 1) == "?" then
        query = remainder:sub(2)
    end
    local params = {}
    for token in query:gmatch("([^&]+)") do
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
    local action = trim(tostring(params.action or "")):lower()
    return action, params
end

function normalizeAppletMode(rawMode)
    local mode = trim(tostring(rawMode or "")):lower()
    if mode == "system" or mode == "run_on_system" or mode == "unsandboxed" then
        return "system"
    end
    return "sandboxed"
end

function packEvent(...)
    return {
        n = select("#", ...),
        ...,
    }
end

function cloneEvent(event)
    local count = tonumber(event and event.n) or #(event or {})
    local copied = { n = count }
    for i = 1, count do
        copied[i] = event[i]
    end
    return copied
end

function ensureAppletWindowForTab(tab, clearContent)
    local target = tab or activeTab()
    local applet = target and target.applet or nil
    if not applet then
        return nil
    end

    local w, h = term.getSize()
    local topRows = effectiveTopBarRows()
    local contentHeight = math.max(1, h - topRows)
    local created = false

    if not applet.window then
        if window and window.create then
            applet.window = window.create(term.current(), 1, topRows + 1, w, contentHeight, true)
        else
            applet.window = term.current()
        end
        created = true
    elseif applet.window.reposition then
        pcall(applet.window.reposition, 1, topRows + 1, w, contentHeight)
    end

    applet.topRows = topRows
    applet.width = w
    applet.height = contentHeight

    if applet.window then
        if applet.window.setVisible then
            local shouldShow = (target == activeTab()) and not state.menuOpen and not state.modal.open
            pcall(applet.window.setVisible, shouldShow and true or false)
        end
        if (created or clearContent) and applet.window.setBackgroundColor and applet.window.clear then
            local bg = target.pageDefaultBackground or currentDefaultBackgroundColorValue()
            local fg = target.pageDefaultForeground or currentDefaultForegroundColorValue(bg)
            pcall(applet.window.setBackgroundColor, bg)
            pcall(applet.window.setTextColor, fg)
            pcall(applet.window.clear)
            pcall(applet.window.setCursorPos, 1, 1)
        end
    end

    return applet.window
end

stopAppletForTab = function(tab, silent)
    local target = tab or activeTab()
    if not target or not target.applet then
        return false
    end
    local applet = target.applet
    if applet.session and not applet.session.done and type(applet.session.terminate) == "function" then
        pcall(applet.session.terminate)
    end
    if applet.window and applet.window.setVisible then
        pcall(applet.window.setVisible, false)
    end
    target.applet = nil
    if not silent then
        target.status = "Applet stopped"
    end
    return true
end

activeAppletRunning = function()
    local tab = activeTab()
    local applet = tab and tab.applet or nil
    return not not (applet and applet.running and applet.session and not applet.session.done)
end

function finalizeAppletForTab(tab)
    local target = tab or activeTab()
    local applet = target and target.applet or nil
    if not applet or not applet.session or not applet.session.done then
        return false
    end

    local sourceUrl = tostring(applet.sourceUrl or target.currentUrl or "")
    local sourceCode = tostring(applet.sourceCode or "")
    local mode = tostring(applet.mode or "sandboxed")
    local runOk = not (applet.session.ok == false)
    local runErr = tostring(applet.session.error or "")

    if applet.window and applet.window.setVisible then
        pcall(applet.window.setVisible, false)
    end
    target.applet = nil
    target.pendingApplet = {
        sourceUrl = sourceUrl,
        sourceCode = sourceCode,
        addToHistory = false,
        trackHistory = shouldTrackNavigationInHistory(sourceUrl),
        tabHistoryCommitted = true,
        browserHistoryCommitted = true,
        historyCommitted = true,
    }

    local statusLine = nil
    if not runOk then
        statusLine = "Execution failed (" .. mode .. "): " .. runErr
        log("applet execution failed (" .. tostring(mode) .. "): " .. tostring(runErr), LogLevel.error)
    else
        log("applet execution finished (" .. tostring(mode) .. "): " .. tostring(sourceUrl), LogLevel.info)
    end

    target.document = buildDocument(
        buildLuaSourceHtml(sourceUrl, sourceCode, "Lua Applet", statusLine, { executable = true }),
        sourceUrl
    )
    target.currentUrl = sourceUrl
    target.urlInput = sourceUrl
    target.urlCursor = #target.urlInput + 1
    target.urlOffset = 0
    target.urlFocus = false
    clearUrlSelection(target)
    clearPageSelection(target)
    target.formState = {}
    target.formMeta = nil
    target.focusedFormControl = nil
    target.renderRevision = 0
    target.lastRenderSignature = nil
    target.aboutUpdateIntervalMs = nil
    target.settingsStickyStatus = nil
    target.scroll = 0
    target.status = runOk and ("Lua Applet: " .. sourceUrl) or ("Lua Applet error: " .. runErr)
    renderDocument(target)
    return true
end

function startLuaAppletSession(luaSource, sourceUrl, mode, tab)
    local target = tab or activeTab()
    stopAppletForTab(target, true)

    target.applet = {
        running = true,
        mode = mode,
        sourceUrl = sourceUrl,
        sourceCode = luaSource,
        session = nil,
        window = nil,
        pausedEvents = {},
        topRows = effectiveTopBarRows(),
    }

    local contentWindow = ensureAppletWindowForTab(target, true)
    if not contentWindow then
        target.applet = nil
        log("applet start failed: window init failed for " .. tostring(sourceUrl), LogLevel.error)
        return false, "Could not initialize applet window"
    end

    local session, sessionErr = sandbox.createAppletSession(luaSource, sourceUrl, mode, contentWindow)
    if not session then
        target.applet = nil
        log("applet start failed (" .. tostring(mode) .. "): " .. tostring(sessionErr), LogLevel.error)
        return false, tostring(sessionErr or "Unknown applet startup error")
    end

    target.applet.session = session
    if session.done then
        finalizeAppletForTab(target)
        return true, nil
    end
    target.status = "Lua applet running (" .. mode .. "): " .. sourceUrl
    log("applet started (" .. tostring(mode) .. "): " .. tostring(sourceUrl), LogLevel.info)
    return true, nil
end

function commitPendingAppletHistory(tab, label)
    local target = tab or activeTab()
    local pending = target and target.pendingApplet or nil
    if not pending then
        return
    end

    if not pending.tabHistoryCommitted then
        if pending.addToHistory then
            pushHistory(target, pending.sourceUrl)
        elseif target.historyIndex > 0 then
            target.history[target.historyIndex] = pending.sourceUrl
        else
            pushHistory(target, pending.sourceUrl)
        end
        pending.tabHistoryCommitted = true
    end

    if pending.trackHistory and not pending.browserHistoryCommitted then
        addBrowserHistory(pending.sourceUrl, label or ("Lua Applet: " .. pending.sourceUrl))
        pending.browserHistoryCommitted = true
    end

    if pending.tabHistoryCommitted and ((not pending.trackHistory) or pending.browserHistoryCommitted) then
        pending.historyCommitted = true
    end
end

function handleAppletActionNavigation(url, tab)
    local target = tab or activeTab()
    local action, params = parseAppletActionUrl(url)
    local pending = target.pendingApplet
    if not pending then
        local message = "No pending applet action in this tab."
        log("applet action ignored: " .. tostring(message), LogLevel.warn)
        target.loading = false
        target.document = buildDocument(makeErrorPage(url, message), url)
        target.currentUrl = url
        target.urlInput = url
        target.urlCursor = #target.urlInput + 1
        target.urlOffset = 0
        target.status = message
        target.renderRevision = 0
        target.lastRenderSignature = nil
        target.scroll = 0
        renderDocument(target)
        draw()
        return false
    end

    local sourceUrl = pending.sourceUrl
    local sourceCode = pending.sourceCode
    local selectedAction = action ~= "" and action or "view_source"

    if selectedAction == "run" then
        local mode = normalizeAppletMode(params.mode)
        log("applet action run requested (" .. tostring(mode) .. "): " .. tostring(sourceUrl), LogLevel.info)
        commitPendingAppletHistory(target, "Lua Applet: " .. sourceUrl)
        target.pendingApplet = {
            sourceUrl = sourceUrl,
            sourceCode = sourceCode,
            addToHistory = false,
            trackHistory = pending.trackHistory,
            tabHistoryCommitted = true,
            browserHistoryCommitted = true,
            historyCommitted = true,
        }

        local started, startErr = startLuaAppletSession(sourceCode, sourceUrl, mode, target)
        if started then
            target.document = buildDocument("<html><body></body></html>", sourceUrl)
            target.status = "Lua applet running (" .. mode .. "): " .. sourceUrl
        else
            log("applet run request failed (" .. tostring(mode) .. "): " .. tostring(startErr), LogLevel.error)
            target.document = buildDocument(
                buildLuaSourceHtml(
                    sourceUrl,
                    sourceCode,
                    "Lua Applet",
                    "Execution failed (" .. mode .. "): " .. tostring(startErr),
                    { executable = true }
                ),
                sourceUrl
            )
            target.status = "Lua applet failed: " .. tostring(startErr)
        end
    else
        log("applet action view source: " .. tostring(sourceUrl), LogLevel.info)
        commitPendingAppletHistory(target, "Lua Source: " .. sourceUrl)
        target.pendingApplet = {
            sourceUrl = sourceUrl,
            sourceCode = sourceCode,
            addToHistory = false,
            trackHistory = pending.trackHistory,
            tabHistoryCommitted = true,
            browserHistoryCommitted = true,
            historyCommitted = true,
        }
        target.document = buildDocument(
            buildLuaSourceHtml(sourceUrl, sourceCode, "Lua Source", nil, { executable = true }),
            sourceUrl
        )
        target.status = sourceUrl
    end

    target.loading = false
    target.currentUrl = sourceUrl
    target.urlInput = sourceUrl
    target.urlCursor = #target.urlInput + 1
    target.urlOffset = 0
    target.urlFocus = false
    clearUrlSelection(target)
    clearPageSelection(target)
    target.formState = {}
    target.formMeta = nil
    target.focusedFormControl = nil
    target.renderRevision = 0
    target.lastRenderSignature = nil
    target.aboutUpdateIntervalMs = nil
    target.settingsStickyStatus = nil
    target.scroll = 0
    renderDocument(target)
    draw()
    if scheduleAboutUpdateTimer then
        scheduleAboutUpdateTimer()
    end
    return true
end

local function midiAnyPlaybackRunning()
    for _, tabItem in ipairs(state.tabs or {}) do
        local midi = tabItem and tabItem.midi or nil
        if midi and midi.mode == "playing" then
            return true
        end
    end
    return false
end

scheduleMidiTimer = function()
    local midiPlayback = state and state.midiPlayback or nil
    if not midiPlayback or not os.startTimer then
        return
    end
    if not midiAnyPlaybackRunning() then
        midiPlayback.timer = nil
        return
    end
    if midiPlayback.timer then
        return
    end
    local interval = tonumber(midiPlayback.intervalSeconds) or 0.05
    if interval <= 0 then
        interval = 0.05
    end
    midiPlayback.timer = os.startTimer(interval)
end

local function midiApplyEventPlayback(midi, event, speaker)
    if not midi or not event then
        return
    end
    if event.kind == "tempo" and tonumber(event.usPerQuarter) and event.usPerQuarter > 0 then
        midi.tempoUsPerQuarter = math.floor(event.usPerQuarter)
        midi.secondsPerTick = (midi.tempoUsPerQuarter / 1000000) / math.max(1, midi.parsed.division or 480)
        return
    end
    if event.kind == "program" then
        local channel = tonumber(event.channel)
        if channel and channel >= 1 and channel <= 16 and tonumber(event.program) then
            midi.channelPrograms[channel] = midiClamp(math.floor(event.program), 0, 127)
        end
        return
    end
    if event.kind ~= "note_on" then
        return
    end
    if not speaker or type(speaker.playNote) ~= "function" then
        return
    end

    local channel = tonumber(event.channel) or 1
    local note = tonumber(event.note) or 54
    local velocity = tonumber(event.velocity) or 96
    local instrument
    if channel == 10 then
        instrument = midiPercussionInstrument(note)
    else
        local program = midi.channelPrograms[channel] or 0
        instrument = midiProgramToInstrument(program)
    end

    local userVolume = tonumber(midi.volume) or MIDI_DEFAULT_VOLUME
    local noteVolume = midiClamp((velocity / 127) * userVolume, 0, 3)
    local pitch = midiNoteToPitch(note)
    pcall(speaker.playNote, instrument, noteVolume, pitch)
end

local function midiStartPlayback(tab)
    local target = tab or activeTab()
    local midi = target and target.midi or nil
    if not midi or not midi.parsed then
        return false, "No MIDI loaded"
    end
    local speaker, speakerName = midiFindSpeaker()
    midi.speakerConnected = not not speaker
    midi.speakerName = speakerName
    if not speaker then
        midi.mode = "stopped"
        midi.lastWallClock = nil
        midi.statusMessage = "No speaker connected. Connect a speaker peripheral."
        return false, midi.statusMessage
    end

    if midi.finished or midi.positionSeconds >= ((tonumber(midi.parsed.totalSeconds) or 0) - 1e-6) then
        resetMidiPlaybackState(midi)
    end
    midi.mode = "playing"
    midi.finished = false
    midi.lastWallClock = os.clock()
    midi.statusMessage = "Playing on " .. tostring(speakerName or "speaker")
    scheduleMidiTimer()
    return true, nil
end

local function midiPausePlayback(tab)
    local target = tab or activeTab()
    local midi = target and target.midi or nil
    if not midi then
        return false, "No MIDI loaded"
    end
    if midi.mode == "playing" then
        midi.mode = "paused"
        midi.lastWallClock = nil
        midi.statusMessage = "Paused"
    end
    return true, nil
end

stopMidiForTab = function(tab, silent)
    local target = tab or activeTab()
    local midi = target and target.midi or nil
    if not midi then
        return false
    end
    midi.mode = "stopped"
    midi.lastWallClock = nil
    midi.finished = false
    if not silent then
        midi.statusMessage = "Stopped"
    end
    target.midi = nil
    scheduleMidiTimer()
    return true
end

local function midiSeekDelta(tab, deltaSeconds)
    local target = tab or activeTab()
    local midi = target and target.midi or nil
    if not midi then
        return false, "No MIDI loaded"
    end
    local current = tonumber(midi.positionSeconds) or 0
    local ok = midiSeekToSeconds(midi, current + (tonumber(deltaSeconds) or 0))
    if not ok then
        return false, "Could not seek"
    end
    midi.finished = false
    midi.statusMessage = "Position updated"
    if midi.mode == "playing" then
        midi.lastWallClock = os.clock()
    end
    return true, nil
end

local function midiSetVolume(tab, value)
    local target = tab or activeTab()
    local midi = target and target.midi or nil
    if not midi then
        return false, "No MIDI loaded"
    end
    local volume = tonumber(value)
    if not volume then
        return false, "Invalid volume"
    end
    midi.volume = midiClamp(volume, 0, 3)
    midi.statusMessage = ("Volume set to %.2f"):format(midi.volume)
    return true, nil
end

handleMidiTimer = function(timerId)
    local midiPlayback = state and state.midiPlayback or nil
    if not midiPlayback or not midiPlayback.timer or timerId ~= midiPlayback.timer then
        return false
    end
    midiPlayback.timer = nil

    local now = os.clock()
    local speaker, speakerName = midiFindSpeaker()
    local changedActive = false
    local active = activeTab()

    for _, tabItem in ipairs(state.tabs or {}) do
        local midi = tabItem and tabItem.midi or nil
        if midi then
            local wasSpeakerConnected = midi.speakerConnected and true or false
            local wasSpeakerName = tostring(midi.speakerName or "")
            midi.speakerConnected = not not speaker
            midi.speakerName = speakerName
            if tabItem == active then
                local nowSpeakerName = tostring(midi.speakerName or "")
                if wasSpeakerConnected ~= midi.speakerConnected or wasSpeakerName ~= nowSpeakerName then
                    changedActive = true
                end
            end
            if midi.mode == "playing" then
                if not speaker then
                    midi.mode = "paused"
                    midi.lastWallClock = nil
                    midi.statusMessage = "Playback paused: no speaker connected."
                    if tabItem == active then
                        changedActive = true
                    end
                else
                    local last = tonumber(midi.lastWallClock) or now
                    local elapsed = now - last
                    if elapsed < 0 then
                        elapsed = 0
                    end
                    midi.lastWallClock = now
                    local remaining = elapsed
                    local events = midi.parsed.events or {}
                    while remaining > 0 and midi.nextEventIndex <= #events do
                        local event = events[midi.nextEventIndex]
                        local eventTick = tonumber(event.tick) or 0
                        local deltaTicks = eventTick - (tonumber(midi.positionTicks) or 0)
                        if deltaTicks < 0 then
                            deltaTicks = 0
                        end
                        local deltaSeconds = deltaTicks * (tonumber(midi.secondsPerTick) or 0)
                        if deltaSeconds > remaining then
                            midi.positionTicks = (tonumber(midi.positionTicks) or 0) +
                                (remaining / math.max(1e-9, tonumber(midi.secondsPerTick) or 1e-9))
                            midi.positionSeconds = (tonumber(midi.positionSeconds) or 0) + remaining
                            remaining = 0
                            break
                        end

                        midi.positionTicks = eventTick
                        midi.positionSeconds = (tonumber(event.timeSeconds) or (tonumber(midi.positionSeconds) or 0))
                        remaining = remaining - deltaSeconds
                        midiApplyEventPlayback(midi, event, speaker)
                        midi.nextEventIndex = midi.nextEventIndex + 1
                    end

                    if remaining > 0 then
                        midi.positionTicks = (tonumber(midi.positionTicks) or 0) +
                            (remaining / math.max(1e-9, tonumber(midi.secondsPerTick) or 1e-9))
                        midi.positionSeconds = (tonumber(midi.positionSeconds) or 0) + remaining
                    end

                    local totalSeconds = tonumber(midi.parsed.totalSeconds) or 0
                    if midi.positionSeconds > totalSeconds then
                        midi.positionSeconds = totalSeconds
                    end
                    if midi.nextEventIndex > #(midi.parsed.events or {}) and midi.positionSeconds >= (totalSeconds - 1e-6) then
                        midi.mode = "stopped"
                        midi.finished = true
                        midi.lastWallClock = nil
                        midi.statusMessage = "Finished"
                    end
                    if tabItem == active then
                        changedActive = true
                    end
                end
            end
        end
    end

    scheduleMidiTimer()
    if changedActive and active and active.midi and not active.loading then
        renderMidiTab(active)
        draw()
    end
    return true
end

function handleMidiActionNavigation(url, tab)
    local target = tab or activeTab()
    local midi = target and target.midi or nil
    local action, params = parseMidiActionUrl(url)
    if action == nil then
        return false
    end
    if not midi then
        target.status = "No MIDI loaded in this tab."
        return false
    end

    local ok, err = true, nil
    if action == "play" then
        ok, err = midiStartPlayback(target)
    elseif action == "pause" then
        ok, err = midiPausePlayback(target)
    elseif action == "stop" then
        resetMidiPlaybackState(midi)
        midi.statusMessage = "Stopped"
    elseif action == "before" then
        ok, err = midiSeekDelta(target, -(tonumber(params.seconds) or 10))
    elseif action == "skip" then
        ok, err = midiSeekDelta(target, tonumber(params.seconds) or 10)
    elseif action == "seek_start" then
        ok = midiSeekToSeconds(midi, 0)
        midi.statusMessage = ok and "Moved to start" or "Could not seek"
    elseif action == "seek_end" then
        ok = midiSeekToSeconds(midi, tonumber(midi.parsed.totalSeconds) or 0)
        midi.statusMessage = ok and "Moved to end" or "Could not seek"
    elseif action == "volume_up" then
        local delta = tonumber(params.delta) or 0.1
        ok, err = midiSetVolume(target, (tonumber(midi.volume) or 1) + delta)
    elseif action == "volume_down" then
        local delta = tonumber(params.delta) or 0.1
        ok, err = midiSetVolume(target, (tonumber(midi.volume) or 1) - delta)
    elseif action == "volume_set" then
        ok, err = midiSetVolume(target, tonumber(params.value))
    else
        ok = false
        err = "Unsupported MIDI action: " .. tostring(action)
    end

    if not ok and err then
        midi.statusMessage = tostring(err)
    end
    if midi.mode == "playing" then
        scheduleMidiTimer()
    end

    renderMidiTab(target)
    draw()
    if scheduleAboutUpdateTimer then
        scheduleAboutUpdateTimer()
    end
    return true
end

function mapEventForApplet(target, event)
    local eventName = event[1]
    if eventName == "term_resize" then
        ensureAppletWindowForTab(target, false)
        return cloneEvent(event)
    end

    if eventName == "mouse_click" or eventName == "mouse_drag" or eventName == "mouse_up" or eventName == "mouse_scroll" then
        local x = tonumber(event[3]) or 1
        local y = tonumber(event[4]) or 1
        local topRows = effectiveTopBarRows()
        local _, h = term.getSize()
        local contentHeight = math.max(1, h - topRows)
        if y <= topRows then
            return nil
        end
        local mappedY = y - topRows
        if mappedY < 1 or mappedY > contentHeight then
            return nil
        end
        return packEvent(eventName, event[2], x, mappedY)
    end

    return cloneEvent(event)
end

function appletHandlesBackgroundEvent(name)
    if name == "mouse_click"
        or name == "mouse_drag"
        or name == "mouse_up"
        or name == "mouse_scroll"
        or name == "key"
        or name == "key_up"
        or name == "char"
        or name == "paste" then
        return false
    end
    return true
end

function appletRunningInTab(tab)
    local applet = tab and tab.applet or nil
    return not not (applet and applet.running and applet.session and not applet.session.done)
end

function isBrowserManagedTimerId(timerId)
    if state.animationTimer and timerId == state.animationTimer then
        return true
    end
    local aboutUpdate = state.aboutUpdate
    if aboutUpdate and aboutUpdate.timer and timerId == aboutUpdate.timer then
        return true
    end
    local midiPlayback = state.midiPlayback
    if midiPlayback and midiPlayback.timer and timerId == midiPlayback.timer then
        return true
    end
    return false
end

function deliverEventToAppletTab(tab, event)
    if not appletRunningInTab(tab) then
        return false
    end

    local applet = tab.applet
    local mapped = mapEventForApplet(tab, event)
    if not mapped then
        return false
    end

    applet.session.deliverEvent(mapped)
    if applet.session.done then
        finalizeAppletForTab(tab)
    end
    return true
end

function enqueuePausedAppletEvent(tab, event)
    if not appletRunningInTab(tab) then
        return false
    end

    local eventName = event and event[1] or nil
    if eventName == "timer" and isBrowserManagedTimerId(event[2]) then
        return false
    end

    local applet = tab.applet
    local queue = applet.pausedEvents
    if type(queue) ~= "table" then
        queue = {}
        applet.pausedEvents = queue
    end

    if #queue >= PAUSED_APPLET_EVENT_MAX then
        return true
    end

    queue[#queue + 1] = cloneEvent(event)
    return true
end

flushPausedAppletQueue = function(tab, maxEvents)
    local target = tab or activeTab()
    if not appletRunningInTab(target) then
        return 0
    end

    local applet = target.applet
    local queue = applet.pausedEvents
    if type(queue) ~= "table" or #queue == 0 then
        return 0
    end

    local remaining = tonumber(maxEvents) or #queue
    remaining = math.max(0, math.floor(remaining))
    local processed = 0

    while remaining > 0 do
        if not appletRunningInTab(target) then
            break
        end

        local currentQueue = target.applet and target.applet.pausedEvents or nil
        if type(currentQueue) ~= "table" or #currentQueue == 0 then
            break
        end

        local queuedEvent = table.remove(currentQueue, 1)
        if not queuedEvent then
            break
        end

        deliverEventToAppletTab(target, queuedEvent)
        processed = processed + 1
        remaining = remaining - 1
    end

    return processed
end

dispatchEventToActiveApplet = function(event)
    return deliverEventToAppletTab(activeTab(), event)
end

function dispatchEventToBackgroundApplets(event)
    local name = event and event[1] or nil
    if not appletHandlesBackgroundEvent(name) then
        return false
    end

    local delivered = false
    local activeIndex = state.activeTab
    local pauseInactive = pauseInactiveAppletsEnabled()
    for index = 1, #state.tabs do
        if index ~= activeIndex then
            local tab = state.tabs[index]
            if appletRunningInTab(tab) then
                if pauseInactive then
                    if enqueuePausedAppletEvent(tab, event) then
                        delivered = true
                    end
                else
                    flushPausedAppletQueue(tab, PAUSED_APPLET_EVENT_MAX)
                    if deliverEventToAppletTab(tab, event) then
                        delivered = true
                    end
                end
            end
        end
    end
    return delivered
end

function finalizeNavigationRender(target)
    target.scroll = 0
    renderDocument(target)
    draw()
    if scheduleAboutUpdateTimer then
        scheduleAboutUpdateTimer()
    end
end

function applyLoadedDocumentToTab(target, finalUrl, document, aboutUpdateIntervalMs, settingsStickyStatus)
    target.document = document
    target.currentUrl = finalUrl
    target.urlInput = finalUrl
    target.urlCursor = #target.urlInput + 1
    target.urlOffset = 0
    target.status = target.document.title or ""
    target.urlFocus = false
    clearUrlSelection(target)
    clearPageSelection(target)
    target.formState = {}
    target.formMeta = nil
    target.focusedFormControl = nil
    target.renderRevision = 0
    target.lastRenderSignature = nil
    target.aboutUpdateIntervalMs = aboutUpdateIntervalMs
    target.settingsStickyStatus = settingsStickyStatus
    target.pendingApplet = nil
    target.midi = nil
end

function commitTabHistoryUrl(target, addToHistory, url)
    if addToHistory then
        pushHistory(target, url)
    elseif target.historyIndex > 0 then
        target.history[target.historyIndex] = url
    else
        pushHistory(target, url)
    end
end

function handleLuaNavigation(target, normalized, allowFallback, requestOptions, addToHistory)
    local body, finalUrl, _, err = fetchTextResource(normalized, allowFallback, requestOptions)
    target.loading = false

    if not body then
        log("lua fetch failed: " .. tostring(normalized) .. " (" .. tostring(err or "Unknown error") .. ")", LogLevel.warn)
        local errUrl = normalized
        local errDocument = buildDocument(makeErrorPage(errUrl, err or "Unknown error"), errUrl)
        applyLoadedDocumentToTab(target, errUrl, errDocument, nil, nil)
        if addToHistory then
            pushHistory(target, errUrl)
        end
        finalizeNavigationRender(target)
        return false
    end

    local resolvedUrl = finalUrl or normalized
    local pendingApplet = {
        sourceUrl = resolvedUrl,
        sourceCode = body,
        addToHistory = addToHistory == true,
        trackHistory = shouldTrackNavigationInHistory(normalized),
        tabHistoryCommitted = false,
        browserHistoryCommitted = false,
        historyCommitted = false,
    }
    commitTabHistoryUrl(target, addToHistory, resolvedUrl)
    pendingApplet.tabHistoryCommitted = true

    local promptDocument = buildDocument(
        buildLuaSourceHtml(resolvedUrl, body, "Lua Source", nil, { executable = true }),
        resolvedUrl
    )
    applyLoadedDocumentToTab(target, resolvedUrl, promptDocument, nil, nil)
    target.pendingApplet = pendingApplet
    target.status = "Executable detected: " .. resolvedUrl
    log("lua source loaded: " .. tostring(resolvedUrl), LogLevel.info)
    finalizeNavigationRender(target)
    return true
end

function handleMidiNavigation(target, normalized, allowFallback, requestOptions, addToHistory)
    local body, finalUrl, _, err = fetchTextResource(normalized, allowFallback, requestOptions)
    target.loading = false

    if not body then
        log("midi fetch failed: " .. tostring(normalized) .. " (" .. tostring(err or "Unknown error") .. ")", LogLevel.warn)
        local errUrl = normalized
        local errDocument = buildDocument(makeErrorPage(errUrl, err or "Unknown error"), errUrl)
        applyLoadedDocumentToTab(target, errUrl, errDocument, nil, nil)
        if addToHistory then
            pushHistory(target, errUrl)
        end
        finalizeNavigationRender(target)
        return false
    end

    local parsed, parseErr = parseMidiData(body)
    local resolvedUrl = finalUrl or normalized
    if not parsed then
        log("midi parse failed: " .. tostring(resolvedUrl) .. " (" .. tostring(parseErr or "Unknown error") .. ")", LogLevel.warn)
        local html = "<html><body><h3>MIDI Parse Error</h3><p><b>URL:</b> "
            .. escapeHtml(resolvedUrl)
            .. "</p><pre>"
            .. escapeHtml(tostring(parseErr or "Unknown error"))
            .. "</pre></body></html>"
        applyLoadedDocumentToTab(target, resolvedUrl, buildDocument(html, resolvedUrl), nil, nil)
        commitTabHistoryUrl(target, addToHistory, resolvedUrl)
        finalizeNavigationRender(target)
        return false
    end

    commitTabHistoryUrl(target, addToHistory, resolvedUrl)
    if shouldTrackNavigationInHistory(normalized) then
        addBrowserHistory(resolvedUrl, "MIDI: " .. midiTrackNameFromUrl(resolvedUrl))
    end

    target.midi = makeMidiPlaybackState(parsed, resolvedUrl)
    local _, speakerName = midiFindSpeaker()
    target.midi.speakerConnected = speakerName ~= nil
    target.midi.speakerName = speakerName
    if not target.midi.speakerConnected then
        target.midi.statusMessage = "No speaker connected. Connect a speaker peripheral."
    end

    renderMidiTab(target)
    target.scroll = 0
    draw()
    if scheduleAboutUpdateTimer then
        scheduleAboutUpdateTimer()
    end
    scheduleMidiTimer()
    log("midi loaded: " .. tostring(resolvedUrl), LogLevel.info)
    return true
end

function handleDocumentNavigation(target, normalized, allowFallback, requestOptions, addToHistory)
    local result, aborted = loadDocumentWithAbort(target, normalized, allowFallback, requestOptions)
    target.loading = false
    if aborted then
        target.status = "Load aborted"
        log("document load aborted: " .. tostring(normalized), LogLevel.warn)
        draw()
        if scheduleAboutUpdateTimer then
            scheduleAboutUpdateTimer()
        end
        return false
    end

    local finalUrl = normalized
    local document = nil
    local aboutUpdateIntervalMs = nil
    local settingsStickyStatus = nil
    if result then
        finalUrl = result.finalUrl or finalUrl
        document = result.document
        aboutUpdateIntervalMs = result.aboutUpdateIntervalMs
        settingsStickyStatus = result.settingsStickyStatus
    end
    if not document then
        log("document render fallback error page: " .. tostring(normalized), LogLevel.warn)
        document = buildDocument(makeErrorPage(normalized, "Unknown error"), normalized)
    end

    applyLoadedDocumentToTab(target, finalUrl, document, aboutUpdateIntervalMs, settingsStickyStatus)
    commitTabHistoryUrl(target, addToHistory, finalUrl)
    if shouldTrackNavigationInHistory(normalized) then
        addBrowserHistory(finalUrl, target.document and target.document.title or "")
    end
    finalizeNavigationRender(target)
    log("document loaded: " .. tostring(finalUrl), LogLevel.info)
    return true
end

navigate = function(rawInput, addToHistory, allowFallback, tab, requestOptions)
    local target = tab or activeTab()
    local normalized, inferred = normalizeInputUrl(rawInput)
    local normalizedLower = trim(tostring(normalized or "")):lower()
    local shouldAllowFallback = allowFallback or inferred
    log("navigate " .. tostring(normalized), LogLevel.info)
    state.highUsage.loadingFrame = true

    stopAppletForTab(target, true)
    stopMidiForTab(target, true)
    target.loading = true
    target.status = "Loading " .. normalized
    target.urlInput = normalized
    target.urlCursor = #target.urlInput + 1
    target.urlOffset = 0
    clearUrlSelection(target)
    draw()

    if isLuaUrl(normalized) then
        return handleLuaNavigation(target, normalized, shouldAllowFallback, requestOptions, addToHistory)
    end
    if isMidiUrl(normalized) then
        return handleMidiNavigation(target, normalized, shouldAllowFallback, requestOptions, addToHistory)
    end
    return handleDocumentNavigation(target, normalized, shouldAllowFallback, requestOptions, addToHistory)
end

function goBack()
    local tab = activeTab()
    if not canGoBack(tab) then
        return
    end
    tab.historyIndex = tab.historyIndex - 1
    navigate(tab.history[tab.historyIndex], false, false, tab)
end

function goForward()
    local tab = activeTab()
    if not canGoForward(tab) then
        return
    end
    tab.historyIndex = tab.historyIndex + 1
    navigate(tab.history[tab.historyIndex], false, false, tab)
end

function reloadPage()
    local tab = activeTab()
    if tab.loading then
        return
    end
    if not tab.currentUrl then
        return
    end
    navigate(tab.currentUrl, false, false, tab)
end

function insertUrlText(text)
    local tab = activeTab()
    if not tab.urlFocus then
        return
    end
    deleteUrlSelection(tab)
    local before = tab.urlInput:sub(1, tab.urlCursor - 1)
    local after = tab.urlInput:sub(tab.urlCursor)
    tab.urlInput = before .. text .. after
    tab.urlCursor = tab.urlCursor + #text
    clearUrlSelection(tab)
end

function deleteUrlBack()
    local tab = activeTab()
    if deleteUrlSelection(tab) then
        return
    end
    if tab.urlCursor <= 1 then
        return
    end
    local before = tab.urlInput:sub(1, tab.urlCursor - 2)
    local after = tab.urlInput:sub(tab.urlCursor)
    tab.urlInput = before .. after
    tab.urlCursor = tab.urlCursor - 1
end

function deleteUrlForward()
    local tab = activeTab()
    if deleteUrlSelection(tab) then
        return
    end
    if tab.urlCursor > #tab.urlInput then
        return
    end
    local before = tab.urlInput:sub(1, tab.urlCursor - 1)
    local after = tab.urlInput:sub(tab.urlCursor + 1)
    tab.urlInput = before .. after
end

