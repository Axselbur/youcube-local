-- YouCube Local: storage node.
-- Run this on EVERY storage PC. It stores file parts and serves them.

local MODEM_SIDE = "back"
local CHANNEL     = 42042
local SLICE       = 32 * 1024
local CAPACITY    = 10 * 1024 * 1024
local ROOT        = "/yc"

local modem = peripheral.find("modem", function(_, w)
    if w.isWired then
        return w.isWired()
    elseif w.isWireless then
        return not w.isWireless()
    end
    return true
end)
if not modem then
    error("No wired modem found")
end
modem.open(CHANNEL)

local me = os.getComputerID()

local function partPath(fileId, part)
    return ROOT .. "/" .. fileId .. "_" .. tostring(part) .. ".bin"
end

local function usedSpace()
    if not fs.exists(ROOT) then
        return 0
    end
    local total = 0
    for _, name in ipairs(fs.list(ROOT)) do
        total = total + (fs.getSize(ROOT .. "/" .. name) or 0)
    end
    return total
end

local function freeSpace()
    local free = CAPACITY - usedSpace()
    if fs.getFreeSpace then
        local f = fs.getFreeSpace("/")
        if f and f > 0 then
            free = math.min(free, f)
        end
    end
    return free
end

local function reply(replyChannel, msg)
    modem.transmit(CHANNEL, replyChannel, msg)
end

local function handle(msg, replyChannel)
    if msg.from == me then
        return
    end

    if msg.c == "ping" then
        reply(replyChannel, {c = "hello", from = me, to = msg.from, free = freeSpace()})

    elseif msg.c == "space" then
        reply(replyChannel, {c = "space", from = me, to = msg.from, free = freeSpace()})

    elseif msg.c == "store" then
        if not fs.exists(ROOT) then
            fs.makeDir(ROOT)
        end
        if freeSpace() < #msg.d then
            reply(replyChannel, {c = "stored", from = me, to = msg.from, f = msg.f, p = msg.p, o = msg.o, ok = false})
            return
        end
        local p = partPath(msg.f, msg.p)
        local f = fs.open(p, "r+b") or fs.open(p, "wb")
        local ok = false
        if f then
            f.seek("set", msg.o)
            f.write(msg.d)
            f.close()
            ok = true
        end
        reply(replyChannel, {c = "stored", from = me, to = msg.from, f = msg.f, p = msg.p, o = msg.o, ok = ok})

    elseif msg.c == "del" then
        local p = partPath(msg.f, msg.p)
        if fs.exists(p) then
            fs.delete(p)
        end
        reply(replyChannel, {c = "deleted", from = me, to = msg.from, f = msg.f, p = msg.p})

    elseif msg.c == "get" then
        local p = partPath(msg.f, msg.p)
        local size = fs.exists(p) and fs.getSize(p) or 0
        if msg.o >= size then
            reply(replyChannel, {c = "eof", from = me, to = msg.from, f = msg.f, p = msg.p})
        else
            local f = fs.open(p, "rb")
            if f then
                f.seek("set", msg.o)
                local left = math.min(msg.n or SLICE, size - msg.o)
                local curOff = msg.o
                while left > 0 do
                    local data = f.read(math.min(SLICE, left))
                    if not data or #data == 0 then
                        break
                    end
                    reply(replyChannel, {c = "data", from = me, to = msg.from, f = msg.f, p = msg.p, o = curOff, d = data})
                    curOff = curOff + #data
                    left = left - #data
                end
                f.close()
            end
        end
    end
end

while true do
    local ok, e, _, chan, replyChannel, msg = pcall(os.pullEvent, "modem_message")
    if ok and e == "modem_message" and chan == CHANNEL and type(msg) == "table" and msg.c then
        pcall(handle, msg, replyChannel)
    end
end
