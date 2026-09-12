-- YouCube Local: setup.
-- Run ONCE on the main PC.
-- Downloads media from GitHub, splits it into parts and distributes them
-- across storage PCs over the wired network.

local MODEM_SIDE = ... or "back"
local CHANNEL     = 42042
local SLICE       = 32 * 1024
local PART_SIZE   = 8 * 1024 * 1024
local FILES_URL   = "https://raw.githubusercontent.com/Axselbur/youcube-local/main/files.json"
local MANIFEST    = "/yc/manifest.json"
local TMP         = "/yc/.tmp"

local modem = peripheral.find("modem", function(_, w)
    if w.isWired then
        return w.isWired()
    elseif w.isWireless then
        return not w.isWireless()
    end
    return true
end)
if not modem then
    error("No wired modem found. Set the side: setup <side>")
end
modem.open(CHANNEL)
local me = os.getComputerID()
print(string.format("I am PC %d, using modem on side: %s", me, MODEM_SIDE))

local function request(msg, to, timeout)
    msg.from = me
    msg.to = to
    modem.transmit(CHANNEL, CHANNEL, msg)
    local t = os.startTimer(timeout or 3)
    while true do
        local e, _, chan, _, got = os.pullEvent()
        if e == "modem_message" and chan == CHANNEL and type(got) == "table"
            and got.to == me and got.from == to then
            os.cancelTimer(t)
            return got
        elseif e == "timer" and chan == t then
            return nil
        end
    end
end

local function discover()
    print("Searching for storage PCs (8 sec) ...")
    local found = {}
    local deadline = os.startTimer(8)
    local nextPing = os.startTimer(0)
    while true do
        local e, _, chan, _, msg = os.pullEvent()
        if e == "timer" and chan == deadline then
            os.cancelTimer(nextPing)
            break
        elseif e == "timer" and chan == nextPing then
            modem.transmit(CHANNEL, CHANNEL, {c = "ping", from = me})
            print("  pinging ...")
            nextPing = os.startTimer(2)
        elseif e == "modem_message" and chan == CHANNEL and type(msg) == "table" then
            if msg.c == "hello" and msg.to == me and not found[msg.from] then
                found[msg.from] = msg.free
                print(string.format("  -> found storage PC %d (%d MB free)", msg.from, math.floor((msg.free or 0) / 1024 / 1024)))
            end
        end
    end
    local pcs = {}
    for id, free in pairs(found) do
        pcs[#pcs + 1] = {id = id, free = free}
    end
    if #pcs == 0 then
        error(
            "No storage PCs found.\n" ..
            "Check:\n" ..
            " 1. store.lua is running on every storage PC\n" ..
            " 2. all PCs are linked with wired modems + rednet cable\n" ..
            " 3. modem sides are correct (run with: setup <side>)"
        )
    end
    return pcs
end

local function sendPart(fileId, partIndex, size, pcs, first)
    local f = fs.open(TMP, "rb")
    if not f then
        return nil
    end
    local placed = nil
    local n = #pcs
    for round = 1, n do
        local pc = pcs[(first + round - 2) % n + 1]
        local okAll = true
        f.seek("set", 0)
        local off = 0
        while off < size do
            local data = f.read(math.min(SLICE, size - off))
            if not data or #data == 0 then
                okAll = false
                break
            end
            local ack = request({c = "store", f = fileId, p = partIndex, o = off, d = data}, pc.id, 5)
            if not ack or not ack.ok then
                okAll = false
                request({c = "del", f = fileId, p = partIndex}, pc.id, 2)
                break
            end
            off = off + #data
        end
        if okAll then
            placed = {pc = pc.id, size = size}
            pc.free = pc.free - size
            break
        end
    end
    f.close()
    return placed
end

local function distribute(fileId, url, pcs, nextPc)
    print("Downloading " .. url)
    local resp = http.get(url, nil, true)
    if not resp then
        error("Failed to download " .. url)
    end

    if not fs.exists("/yc") then
        fs.makeDir("/yc")
    end

    local parts = {}
    local partIndex = 0
    local partSize = 0
    local totalSize = 0

    local tmp = fs.open(TMP, "wb")
    if not tmp then
        error("Cannot open temp file")
    end

    while true do
        local chunk = resp.read(SLICE)
        if not chunk or #chunk == 0 then
            break
        end
        tmp.write(chunk)
        partSize = partSize + #chunk
        totalSize = totalSize + #chunk
        if partSize >= PART_SIZE then
            tmp.close()
            local placed = sendPart(fileId, partIndex, partSize, pcs, nextPc)
            if not placed then
                error("Not enough space on storage PCs")
            end
            parts[#parts + 1] = placed
            partIndex = partIndex + 1
            partSize = 0
            nextPc = nextPc % #pcs + 1
            tmp = fs.open(TMP, "wb")
        end
    end

    if partSize > 0 then
        tmp.close()
        local placed = sendPart(fileId, partIndex, partSize, pcs, nextPc)
        if not placed then
            error("Not enough space on storage PCs")
        end
        parts[#parts + 1] = placed
    end

    resp.close()
    if fs.exists(TMP) then
        fs.delete(TMP)
    end
    return {size = totalSize, parts = parts}
end

local function main()
    print("=== YouCube Local setup ===")
    local pcs = discover()

    print("Fetching file list ...")
    local resp = http.get(FILES_URL, nil, true)
    if not resp then
        error("Failed to fetch files.json")
    end
    local list = textutils.unserialiseJSON(resp.readAll())
    resp.close()

    local manifest = {files = {}}
    local nextPc = 1
    for _, entry in ipairs(list.files) do
        print(string.format("File %s (%s) ...", entry.id, entry.type))
        local placed = distribute(entry.id, entry.url, pcs, nextPc)
        nextPc = nextPc % #pcs + 1
        manifest.files[#manifest.files + 1] = {
            id = entry.id,
            type = entry.type,
            size = placed.size,
            parts = placed.parts,
        }
        print(string.format("  OK: %d MB in %d part(s)", math.floor(placed.size / 1024 / 1024), #placed.parts))
    end

    local f = fs.open(MANIFEST, "wb")
    f.write(textutils.serialiseJSON(manifest))
    f.close()
    print("Done! Now run: player")
end

local ok, err = pcall(main)
if not ok then
    printError(err)
end
