-- Runs T128Telemetry.lua outside the game against stubs of the GIANTS functions it calls.
-- Checks the mod's logic and the file it produces, not the real game API.
--   lua fs-mod/tests/run_mock.lua <output dir>
local outDir = (arg[1] or "."):gsub("/*$", "/")
local realOpen = io.open

-- ---- engine stubs ----------------------------------------------------------
local xmlFiles, listener = {}, nil
function getUserProfileAppPath() return outDir end
function createFolder(path) os.execute('mkdir -p "' .. path .. '"') end
function createXMLFile(_, path, root)
    xmlFiles[#xmlFiles + 1] = {path = path, root = root, keys = {}, values = {}}
    return #xmlFiles
end
function setXMLInt(id, key, value)
    assert(math.type(value) == "integer", key .. " must be an integer, got " .. tostring(value))
    local f, name = xmlFiles[id], key:match("^telemetry#(%w+)$")
    assert(name, "unexpected key " .. key)
    if f.values[name] == nil then f.keys[#f.keys + 1] = name end
    f.values[name] = value
end
function saveXMLFile(id)
    local f, attrs = xmlFiles[id], {}
    for _, k in ipairs(f.keys) do attrs[#attrs + 1] = string.format('%s="%d"', k, f.values[k]) end
    local h = assert(realOpen(f.path, "w"))
    h:write('<?xml version="1.0" encoding="utf-8" standalone="no"?>\n<', f.root, " ", table.concat(attrs, " "), "/>\n")
    h:close()
end
function delete(id) xmlFiles[id].deleted = true end
function addModEventListener(l) listener = l end
local gamepads = {"Thrustmaster Advance Racer"}
function getNumOfGamepads() return #gamepads end
function getGamepadName(i) return assert(gamepads[i + 1], "gamepad index out of range") end
Lights = {TURNLIGHT_OFF = 0, TURNLIGHT_LEFT = 1, TURNLIGHT_RIGHT = 2, TURNLIGHT_HAZARD = 3}

-- ---- a tractor ---------------------------------------------------------------
local motor = {rpm = 1449.6}
function motor:getMinRpm() return 850 end
function motor:getMaxRpm() return 2200 end
function motor:getLastModulatedMotorRpm() return self.rpm end
local tractor = {started = true, spec_motorized = {motor = motor}, spec_lights = {turnLightState = Lights.TURNLIGHT_OFF}}
function tractor:getIsMotorStarted() return self.started end
function tractor:getLastSpeed() return 17.4 end
local current = nil
g_localPlayer = {getCurrentVehicle = function() return current end}

-- ---- helpers -----------------------------------------------------------------
local here = arg[0]:match("^(.*)/[^/]*$") or "."
dofile(here .. "/../FS25_T128Telemetry/T128Telemetry.lua")
assert(listener == T128Telemetry, "mod did not register itself")
local path = outDir .. T128Telemetry.FOLDER .. T128Telemetry.FILE

local function read()   -- the telemetry file as a table; empty if it does not exist
    local values, h = {}, realOpen(path, "r")
    if h ~= nil then
        for name, value in h:read("a"):gmatch('(%w+)="(%-?%d+)"') do values[name] = tonumber(value) end
        h:close()
    end
    return values
end
local function seqNow() return read().seq or 0 end
local function run(ms) for _ = 1, ms / 16 do listener:update(16) end end
local function tick()   -- one write interval's worth of 16 ms frames
    local seq = seqNow()
    run(64)
    assert(seqNow() == seq + 1, "expected exactly one write per 50 ms")
    return read()
end
local function expect(v, want)
    for k, w in pairs(want) do assert(v[k] == w, string.format("%s: expected %s, got %s", k, w, tostring(v[k]))) end
end
local CHECK = T128Telemetry.DEVICE_CHECK_INTERVAL_MS

-- ---- run once per write method -------------------------------------------------
local function scenario(method)
    gamepads = {"Thrustmaster Advance Racer"}
    current = nil; tractor.started = true; tractor.spec_lights.turnLightState = Lights.TURNLIGHT_OFF
    os.remove(path)
    listener:loadMap()
    expect(tick(), {active = 0, motor = 0, rpm = 0, turn = 0})                       -- on foot
    assert(listener.writeMethod == method, "expected write method " .. method .. ", got " .. tostring(listener.writeMethod))

    current = tractor
    expect(tick(), {active = 1, motor = 1, rpm = 1450, minRpm = 850, maxRpm = 2200, speed = 17, turn = 0})

    tractor.spec_lights.turnLightState = Lights.TURNLIGHT_LEFT;   expect(tick(), {turn = 1})
    tractor.spec_lights.turnLightState = Lights.TURNLIGHT_RIGHT;  expect(tick(), {turn = 2})
    tractor.spec_lights.turnLightState = Lights.TURNLIGHT_HAZARD; expect(tick(), {turn = 3})

    tractor.started = false
    expect(tick(), {active = 1, motor = 0, rpm = 0, turn = 3})                       -- hazards, engine off

    current = {spec_lights = {turnLightState = Lights.TURNLIGHT_LEFT}}               -- no motor: ignored
    expect(tick(), {active = 0, turn = 0})

    tractor.started = true; tractor.spec_lights.turnLightState = Lights.TURNLIGHT_RIGHT; current = tractor
    expect(tick(), {active = 1, motor = 1, turn = 2})

    -- Wheel unplugged: noticed within one device check, one final "off" record, then silence
    gamepads = {"Xbox Controller", "Logitech G29 Driving Force Racing Wheel USB"}
    run(CHECK + 16)
    expect(read(), {active = 0, motor = 0, rpm = 0, turn = 0})
    local seq = seqNow()
    run(5000)
    assert(seqNow() == seq, "mod kept writing with no wheel connected")

    -- Plugged back in (name matching ignores case): writes resume
    gamepads = {"Xbox Controller", "THRUSTMASTER T128"}
    run(CHECK + 64)
    assert(seqNow() > seq, "mod did not resume when the wheel came back")
    expect(tick(), {active = 1, motor = 1, turn = 2})

    -- An engine that cannot list controllers: stay on rather than never work
    gamepads = {}
    run(CHECK + 16)
    assert(not listener.enabled and T128Telemetry.listControllers() == "(none)")
    local realCount = getNumOfGamepads
    getNumOfGamepads = nil
    run(CHECK + 16)
    assert(listener.enabled, "should stay on when controllers cannot be listed")
    getNumOfGamepads = realCount

    -- Leaving the savegame ends on an "off" record
    listener:deleteMap()
    expect(read(), {active = 0, motor = 0, turn = 0})

    -- Loading a savegame with no wheel writes nothing until one shows up
    os.remove(path)
    listener:loadMap()
    run(1000)
    assert(next(read()) == nil, "wrote telemetry with no wheel at load")
    gamepads = {"Thrustmaster Advance Racer"}
    run(CHECK + 16)
    expect(tick(), {active = 1, motor = 1, rpm = 1450, turn = 2})
end

scenario("io")

-- A game that refuses io.open: the mod falls back to the XML functions
listener:deleteMap()
io.open = function() return nil end
scenario("xml")
io.open = realOpen

print("mock run ok, wrote " .. path)
