-- Runs T128Telemetry.lua outside the game against stubs of the GIANTS functions it calls,
-- with this script playing the bridge (it writes bridge.xml the way the real one does).
-- Checks the mod's logic and the file it produces, not the real game API.
--   lua fs-mod/tests/run_mock.lua <output dir>
local outDir = (arg[1] or "."):gsub("/*$", "/")
local realOpen = io.open

-- ---- engine stubs ----------------------------------------------------------
local xmlFiles, listener, foldersCreated, logLines = {}, nil, 0, {}
local realPrint = print
function print(...) logLines[#logLines + 1] = table.concat({...}, " ") end
local function logged(fragment)
    local n = 0
    for _, line in ipairs(logLines) do if line:find(fragment, 1, true) then n = n + 1 end end
    return n
end

function getUserProfileAppPath() return outDir end
function createFolder(path) foldersCreated = foldersCreated + 1; os.execute('mkdir -p "' .. path .. '"') end
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

local function slurp(path)
    local h = realOpen(path, "r")
    if h == nil then return nil end
    local text = h:read("a"); h:close()
    return text
end
local function attrs(text)
    local values = {}
    for name, value in (text or ""):gmatch('(%w+)="(%-?%d+)"') do values[name] = tonumber(value) end
    return values
end

-- Both ways the game can read XML; a file that is not well-formed gives no handle.
function fileExists(path) return slurp(path) ~= nil end
local function parseXml(path)
    local text = slurp(path)
    if text == nil or not text:find("^<%?xml.-%?>%s*<%w+.-/>%s*$") then return nil end
    return attrs(text)
end
local function xmlClass()
    return {loadIfExists = function(_, path)
        local values = parseXml(path)
        if values == nil then return nil end
        return {getInt = function(_, key) return values[key:match("#(%w+)$")] end, delete = function() end}
    end}
end
local readHandles = {}
local function xmlFunctions()
    loadXMLFile = function(_, path)
        local values = parseXml(path)
        if values == nil then return 0 end
        readHandles[#readHandles + 1] = values
        return -#readHandles
    end
    getXMLInt = function(handle, key) return readHandles[-handle][key:match("#(%w+)$")] end
end
local realDelete = delete
function delete(id) if id > 0 then realDelete(id) end end

local gamepads = {}
function getNumOfGamepads() return #gamepads end
function getGamepadName(i) return assert(gamepads[i + 1], "gamepad index out of range") end
Lights = {TURNLIGHT_OFF = 0, TURNLIGHT_LEFT = 1, TURNLIGHT_RIGHT = 2, TURNLIGHT_HAZARD = 3}

-- ---- a tractor ---------------------------------------------------------------
local vehicleQueries = 0
local motor = {rpm = 1449.6}
function motor:getMinRpm() vehicleQueries = vehicleQueries + 1; return 850 end
function motor:getMaxRpm() return 2200 end
function motor:getLastModulatedMotorRpm() return self.rpm end
local tractor = {started = true, spec_motorized = {motor = motor}, spec_lights = {turnLightState = Lights.TURNLIGHT_OFF}}
function tractor:getIsMotorStarted() return self.started end
function tractor:getLastSpeed() return 17.4 end
local current = nil
g_localPlayer = {getCurrentVehicle = function() return current end}

-- ---- the mod, and this script as the bridge ------------------------------------
local here = arg[0]:match("^(.*)/[^/]*$") or "."
dofile(here .. "/../FS25_T128Telemetry/T128Telemetry.lua")
assert(listener == T128Telemetry, "mod did not register itself")
local folder = outDir .. T128Telemetry.FOLDER
local path, bridgePath = folder .. T128Telemetry.FILE, folder .. T128Telemetry.BRIDGE_FILE
local CHECK = T128Telemetry.CHECK_INTERVAL_MS

local bridge = {running = false, wheel = 1, beat = 0, clock = 0}
local function beat(text)
    os.execute('mkdir -p "' .. folder .. '"')
    bridge.beat = bridge.beat + 1
    local h = assert(realOpen(bridgePath, "w"))
    h:write(text or string.format('<?xml version="1.0" encoding="utf-8" standalone="no"?>\n<bridge version="1" beat="%d" wheel="%d"/>\n', bridge.beat, bridge.wheel))
    h:close()
end
local function run(ms)   -- 16 ms frames; a running bridge beats every 500 ms
    for _ = 1, ms / 16 do
        bridge.clock = bridge.clock + 16
        if bridge.running and bridge.clock >= 500 then bridge.clock = 0; beat() end
        listener:update(16)
    end
end
local function read() return attrs(slurp(path)) end   -- the telemetry file; empty if there is none
local function seqNow() return read().seq or 0 end
local function tick()   -- one write interval's worth of frames
    local seq = seqNow()
    run(64)
    assert(seqNow() == seq + 1, "expected exactly one write per 50 ms")
    return read()
end
local function expect(v, want)
    for k, w in pairs(want) do assert(v[k] == w, string.format("%s: expected %s, got %s", k, w, tostring(v[k]))) end
end
local function reset()
    if listener.path ~= nil then listener:deleteMap() end
    os.remove(path); os.remove(bridgePath)
    bridge.running, bridge.wheel, bridge.clock = false, 1, 0
    gamepads = {}; current = nil; vehicleQueries = 0; foldersCreated = 0; logLines = {}
    tractor.started = true; tractor.spec_lights.turnLightState = Lights.TURNLIGHT_OFF
    motor.getMinRpm = function() vehicleQueries = vehicleQueries + 1; return 850 end
end
local function silent(ms, why)
    local seq = seqNow()
    run(ms)
    assert(not listener.enabled and seqNow() == seq, why)
end

-- ---- a player without the bridge (everyone else in a multiplayer game) ------------
local function guest()
    reset()
    gamepads = {"Thrustmaster T300RS", "Xbox Controller"}   -- owning other Thrustmaster gear changes nothing
    current = tractor
    listener:loadMap()
    run(10000)
    assert(not listener.enabled, "mod switched on without a bridge")
    assert(slurp(path) == nil, "telemetry written without a bridge")
    assert(foldersCreated == 0, "folder created without a bridge")
    assert(vehicleQueries == 0, "vehicle queried without a bridge")
    assert(#logLines == 1, "expected one log line for an idle player, got " .. #logLines)
end

-- ---- the wheel's owner -----------------------------------------------------------
local function owner(writeMethod)
    reset()
    listener:loadMap()
    silent(2000, "on before the bridge started")

    bridge.running = true                                     -- bridge starts, wheel connected
    run(2 * CHECK + 600)
    assert(listener.enabled, "bridge with wheel did not switch the mod on")
    expect(tick(), {active = 0, motor = 0, rpm = 0, turn = 0})                       -- on foot
    assert(listener.writeMethod == writeMethod, "write method " .. tostring(listener.writeMethod))

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

    bridge.wheel = 0                                          -- wheel unplugged, bridge still running
    run(CHECK + 600)
    expect(read(), {active = 0, motor = 0, rpm = 0, turn = 0})                       -- one last "off" record
    silent(5000, "kept writing with the wheel unplugged")

    bridge.wheel = 1                                          -- plugged back in
    run(CHECK + 600)
    expect(tick(), {active = 1, motor = 1, turn = 2})

    bridge.running = false; os.remove(bridgePath)             -- bridge closed: its file is gone
    run(CHECK + 16)
    silent(3000, "kept writing after the bridge closed")

    bridge.running = true                                     -- bridge started again
    run(2 * CHECK + 600)
    expect(tick(), {active = 1, motor = 1, turn = 2})

    bridge.running = false                                    -- bridge crashed: file stays, beat frozen
    run((T128Telemetry.BRIDGE_MISSED_CHECKS + 1) * CHECK + 16)   -- the last beat may land just after a check
    silent(3000, "kept writing after the bridge stopped beating")

    listener:deleteMap(); listener:loadMap()                  -- next savegame, leftover file still there
    silent(6000, "a leftover bridge.xml switched the mod on")

    bridge.running = true                                     -- leaving the savegame ends on "off"
    run(2 * CHECK + 600)
    expect(tick(), {active = 1})
    listener:deleteMap()
    expect(read(), {active = 0, motor = 0, turn = 0})
    assert(logged("stopped after an error") == 0)
end

-- ---- games where bridge.xml cannot be read: fall back to controller names -----------
local function fallback()
    reset()
    gamepads = {"Xbox Controller", "THRUSTMASTER Advance Racer"}
    current = tractor
    listener:loadMap()
    assert(listener.enabled and logged("controller names") == 1, "no reader should mean going by names")
    expect(tick(), {active = 1, motor = 1})
    gamepads = {"Xbox Controller"}
    run(CHECK + 16)
    silent(3000, "kept writing with no wheel listed")
    gamepads = {}
    local saved = getNumOfGamepads
    getNumOfGamepads = nil                                    -- cannot list either: stay off
    run(2 * CHECK)
    assert(not listener.enabled)
    getNumOfGamepads = saved
end

local function unreadable()                                    -- a reader exists but never gets a beat
    reset()
    gamepads = {"Thrustmaster Advance Racer"}
    listener:loadMap()
    for _ = 1, T128Telemetry.BRIDGE_UNREADABLE_CHECKS do beat('<bridge version="2" beat="oops"'); run(CHECK + 16) end
    assert(listener.bridgeReader == nil and logged("cannot read") == 1, "should give up on an unreadable bridge.xml")
    assert(listener.enabled, "should go by controller names once bridge.xml is given up on")
end

-- ---- never repeat a fault, never run on a dedicated server ---------------------------
local function faults()
    reset()
    listener:loadMap()
    bridge.running = true; current = tractor
    run(2 * CHECK + 600)
    assert(listener.enabled)
    motor.getMinRpm = function() error("boom") end
    run(2000)
    assert(logged("stopped after an error") == 1 and not listener.enabled, "an error should stop the mod, once")

    reset()
    g_dedicatedServer = {}
    listener:loadMap(); run(5000)
    assert(listener.path == nil and #logLines == 0 and foldersCreated == 0, "should be inert on a dedicated server")
    g_dedicatedServer = nil
end

XMLFile = xmlClass()
guest(); owner("io"); unreadable(); faults()

XMLFile = nil; xmlFunctions()                                  -- older engine functions instead of the class
guest(); owner("io")
io.open = function() return nil end                            -- a game that refuses io.open
owner("xml")
io.open = realOpen

loadXMLFile, getXMLInt = nil, nil                              -- no way to read bridge.xml at all
fallback()

reset()
realPrint("mock run ok")
