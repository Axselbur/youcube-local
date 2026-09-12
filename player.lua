-- YouCube Local: player.
-- Run on the main PC. Plays files from the local storage network.

local MODEM_SIDE = "back"
local CHANNEL     = 42042
local SLICE       = 32 * 1024
local MANIFEST    = "/yc/manifest.json"
local VOLUME      = 3
local STOP_KEY    = keys.s

-- Video display: "term" (computer screen), "monitor" (single monitor side)
-- or "grid" (several monitors, see GRID below)
local VIDEO_DISPLAY = "term"
local MONITOR_SIDE  = "right"
local GRID = {
    -- {"right", 0, 0},
    -- {"left", 26, 0},
    -- {"top", 52, 0},
    -- {"bottom", 78, 0},
}

local modem = peripheral.find("modem", function(_, w) return w.isWired() end)
if not modem then
    error("No wired modem found")
end
modem.open(CHANNEL)
local me = os.getComputerID()

local function NetFile(id, parts)
    local self = {id = id, parts = parts, pi = 1, off = 0, buf = ""}

    function self:fetch(want)
        local part = self.parts[self.pi]
        if not part then
            return nil
        end
        local got = {}
        local total = 0
        local t = os.startTimer(10)
        modem.transmit(CHANNEL, CHANNEL, {
            c = "get", from = me, to = part.pc,
            f = self.id, p = self.pi - 1, o = self.off, n = want,
        })
        while total < want do
            local e, _, chan, _, msg = os.pullEvent()
            if e == "modem_message" and chan == CHANNEL and type(msg) == "table"
                and msg.to == me and msg.from == part.pc
                and msg.f == self.id and msg.p == (self.pi - 1) then
                if msg.c == "data" then
                    got[#got + 1] = msg.d
                    total = total + #msg.d
                    os.cancelTimer(t)
                    t = os.startTimer(10)
                elseif msg.c == "eof" then
                    os.cancelTimer(t)
                    break
                end
            elseif e == "timer" and chan == t then
                os.cancelTimer(t)
                break
            end
        end
        if total == 0 then
            return nil
        end
        self.off = self.off + total
        return table.concat(got)
    end

    function self:read(n)
        while self.pi <= #self.parts do
            local part = self.parts[self.pi]
            if self.off >= part.size then
                self.pi = self.pi + 1
                self.off = 0
            else
                local want = math.min(n, part.size - self.off)
                local data = self:fetch(want) or self:fetch(want)
                if data and #data > 0 then
                    return data
                end
                error("Network read failed")
            end
        end
        return nil
    end

    function self:readLine()
        while true do
            local nl = self.buf:find("\n", 1, true)
            if nl then
                local line = self.buf:sub(1, nl - 1)
                self.buf = self.buf:sub(nl + 1)
                return line
            end
            local data = self:read(SLICE)
            if not data then
                if #self.buf > 0 then
                    local b = self.buf
                    self.buf = ""
                    return b
                end
                return nil
            end
            self.buf = self.buf .. data
        end
    end

    return self
end

local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local b64map = {}
for i = 1, #b64chars do
    b64map[b64chars:sub(i, i)] = i - 1
end

local function b64decode(s)
    s = s:gsub("[^" .. b64chars .. "=]", "")
    local out = {}
    local buffer = 0
    local bits = 0
    for i = 1, #s do
        local ch = s:sub(i, i)
        if ch == "=" then
            break
        end
        buffer = buffer * 64 + b64map[ch]
        bits = bits + 6
        if bits >= 8 then
            bits = bits - 8
            out[#out + 1] = string.char(math.floor(buffer / 2 ^ bits) % 256)
        end
    end
    return table.concat(out)
end

local function buildScreens()
    if VIDEO_DISPLAY == "monitor" then
        local m = peripheral.wrap(MONITOR_SIDE)
        if not m then
            error("No monitor on side " .. MONITOR_SIDE)
        end
        local w, h = m.getSize()
        return {{t = m, x = 0, y = 0, w = w, h = h}}
    elseif VIDEO_DISPLAY == "grid" then
        local screens = {}
        for _, entry in ipairs(GRID) do
            local m = peripheral.wrap(entry[1])
            local w, h = m.getSize()
            screens[#screens + 1] = {t = m, x = entry[2], y = entry[3], w = w, h = h}
        end
        return screens
    end
    local t = term.current() or term
    local w, h = t.getSize()
    return {{t = t, x = 0, y = 0, w = w, h = h}}
end

local function playVideo(netFile)
    local screens = buildScreens()
    for _, s in ipairs(screens) do
        s.t.setBackgroundColor(colors.black)
        s.t.clear()
        s.t.setCursorPos(1, 1)
    end

    local header = netFile:readLine()
    if header ~= "32Vid 1.1" then
        error("Unsupported video file")
    end
    local fps = tonumber(netFile:readLine()) or 0

    local frameCount = 0
    local start = os.epoch("utc")
    while true do
        local frame = netFile:readLine()
        if frame == nil or frame == "" then
            break
        end

        local mode = frame:match("^!CP([CD])")
        if not mode then
            error("Invalid video file")
        end
        local len, b64data
        if mode == "C" then
            len = tonumber(frame:sub(5, 8), 16)
            b64data = frame:sub(9, len + 8)
        else
            len = tonumber(frame:sub(5, 16), 16)
            b64data = frame:sub(17, len + 16)
        end
        local data = b64decode(b64data)

        local width = data:byte(5) + data:byte(6) * 256
        local height = data:byte(7) + data:byte(8) * 256

        local pos = 17
        local c = data:sub(pos, pos)
        pos = pos + 1
        local n = data:byte(pos)
        pos = pos + 1

        local text = {}
        for y = 1, height do
            local row = {}
            for x = 1, width do
                row[x] = c
                n = n - 1
                if n == 0 then
                    c = data:sub(pos, pos)
                    pos = pos + 1
                    n = data:byte(pos)
                    pos = pos + 1
                end
            end
            text[y] = table.concat(row)
        end

        local cb = c:byte()
        local fg, bg = {}, {}
        for y = 1, height do
            local frow, brow = {}, {}
            for x = 1, width do
                frow[x] = ("%x"):format(bit32.band(cb, 0x0F))
                brow[x] = ("%x"):format(bit32.rshift(cb, 4))
                n = n - 1
                if n == 0 then
                    cb = data:byte(pos)
                    pos = pos + 1
                    n = data:byte(pos)
                    pos = pos + 1
                end
            end
            fg[y] = table.concat(frow)
            bg[y] = table.concat(brow)
        end

        pos = pos - 2
        for i = 0, 15 do
            local r = data:byte(pos)
            local g = data:byte(pos + 1)
            local b = data:byte(pos + 2)
            pos = pos + 3
            local col = 2 ^ i
            for _, s in ipairs(screens) do
                s.t.setPaletteColor(col, r / 255, g / 255, b / 255)
            end
        end

        for _, s in ipairs(screens) do
            local x0 = math.max(s.x, 0)
            local y0 = math.max(s.y, 0)
            local x1 = math.min(s.x + s.w, width)
            local y1 = math.min(s.y + s.h, height)
            if x0 < x1 and y0 < y1 then
                for y = y0 + 1, y1 do
                    s.t.setCursorPos(1, y - s.y)
                    s.t.blit(
                        text[y]:sub(x0 + 1, x1),
                        fg[y]:sub(x0 + 1, x1),
                        bg[y]:sub(x0 + 1, x1)
                    )
                end
            end
        end

        frameCount = frameCount + 1
        if fps > 0 then
            while os.epoch("utc") < start + (frameCount + 1) / fps * 1000 do
                sleep(1 / fps)
            end
        end
    end

    for _, s in ipairs(screens) do
        s.t.setBackgroundColor(colors.black)
        s.t.setTextColor(colors.white)
        s.t.clear()
        s.t.setCursorPos(1, 1)
    end
end

local function playAudio(netFile)
    local ok, dfpwm = pcall(require, "cc.audio.dfpwm")
    if not ok then
        error("This ComputerCraft version has no DFPWM support")
    end
    local speaker = peripheral.find("speaker")
    if not speaker then
        error("No speaker found")
    end
    local decoder = dfpwm.make_decoder()
    while true do
        local chunk = netFile:read(64 * 1024)
        if not chunk then
            break
        end
        local pcm = decoder(chunk)
        while not speaker.playAudio(pcm, VOLUME) do
            os.pullEvent("speaker_audio_empty")
        end
    end
    speaker.stop()
end

local function loadManifest()
    local f = fs.open(MANIFEST, "rb")
    if not f then
        error("No manifest found. Run: setup")
    end
    local data = textutils.unserialiseJSON(f.readAll())
    f.close()
    return data
end

local function stopEverything()
    local speaker = peripheral.find("speaker")
    if speaker then
        speaker.stop()
    end
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
end

local function main()
    local manifest = loadManifest()

    local items = {}
    for _, file in ipairs(manifest.files) do
        local item = items[file.id]
        if not item then
            item = {id = file.id}
            items[file.id] = item
            items[#items + 1] = item
        end
        if file.type == "audio" then
            item.audio = file
        else
            item.video = file
        end
    end

    while true do
        term.clear()
        term.setCursorPos(1, 1)
        print("=== YouCube Local ===")
        for i, item in ipairs(items) do
            local kind = "audio+video"
            if item.audio and not item.video then
                kind = "audio"
            elseif item.video and not item.audio then
                kind = "video"
            end
            print(i .. ". " .. item.id .. " [" .. kind .. "]")
        end
        print("q. quit")
        term.write("> ")
        local choice = read()
        if choice == "q" then
            break
        end
        local idx = tonumber(choice)
        local item = idx and items[idx]
        if item then
            local tasks = {}
            if item.audio then
                tasks[#tasks + 1] = function()
                    playAudio(NetFile(item.audio.id, item.audio.parts))
                end
            end
            if item.video then
                tasks[#tasks + 1] = function()
                    playVideo(NetFile(item.video.id, item.video.parts))
                end
            end
            tasks[#tasks + 1] = function()
                while true do
                    local _, key = os.pullEvent("key")
                    if key == STOP_KEY then
                        break
                    end
                end
            end
            local ok, err = pcall(function()
                parallel.waitForAny(unpack(tasks))
            end)
            stopEverything()
            if not ok then
                printError(err)
                sleep(2)
            end
        end
    end
end

local ok, err = pcall(main)
if not ok then
    printError(err)
    sleep(3)
end
