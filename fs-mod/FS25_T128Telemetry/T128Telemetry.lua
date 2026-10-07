-- T128Telemetry: writes the driven vehicle's engine RPM and turn-signal state to
-- <profile>/modSettings/FS25_T128Telemetry/telemetry.xml about 20 times a second.
-- The Windows bridge (bridge/fs25_t128_leds.c) polls that file and drives the wheel LEDs.
-- Mod scripts have no sockets, so a small file is the only way out of the game.
-- The game API used here matches what the sister mod FS25_MozaYokeLink uses in-game.
--
-- In multiplayer every player has to load this mod, wheel or not. So it does nothing at
-- all (no folder, no file, no vehicle queries) until the bridge on the same PC says, through
-- bridge.xml, that it is running and has the wheel. See "wheel availability" below.

T128Telemetry = {}

T128Telemetry.VERSION = "0.1.2.0"   -- same as modDesc.xml and the bridge (checked by scripts/package-release.sh)
T128Telemetry.WRITE_INTERVAL_MS = 50
T128Telemetry.FOLDER = "modSettings/FS25_T128Telemetry/"
T128Telemetry.FILE = "telemetry.xml"

-- The bridge rewrites bridge.xml twice a second: <bridge version="1" beat="N" wheel="0|1"/>.
T128Telemetry.BRIDGE_FILE = "bridge.xml"
T128Telemetry.BRIDGE_FORMAT = 1
T128Telemetry.CHECK_INTERVAL_MS = 1000
T128Telemetry.BRIDGE_MISSED_CHECKS = 3       -- beat unchanged for this many checks: bridge gone
T128Telemetry.BRIDGE_UNREADABLE_CHECKS = 5   -- file there but unreadable this often: stop asking

-- Only used when this game cannot read bridge.xml: lower-case fragments of the
-- controller names that count as the wheel.
T128Telemetry.DEVICE_NAMES = {"thrustmaster", "t128", "advance racer"}

-- Values written to the "turn" attribute. Kept separate from the game's own
-- Lights.TURNLIGHT_* numbers so the bridge does not depend on them.
T128Telemetry.TURN_OFF = 0
T128Telemetry.TURN_LEFT = 1
T128Telemetry.TURN_RIGHT = 2
T128Telemetry.TURN_HAZARD = 3

function T128Telemetry:loadMap()
    self.timer = 0
    self.checkTimer = 0
    self.seq = 0
    self.folder = nil
    self.path = nil
    self.xml = nil
    self.writeMethod = nil
    self.enabled = false

    self.bridgeReader = nil
    self.lastBeat = nil
    self.bridgeMissed = T128Telemetry.BRIDGE_MISSED_CHECKS
    self.bridgeUnreadable = 0
    self.bridgeHasWheel = false

    if g_dedicatedServer ~= nil or g_dedicatedServerInfo ~= nil or getUserProfileAppPath == nil then
        return
    end

    self.folder = getUserProfileAppPath() .. T128Telemetry.FOLDER
    self.path = self.folder .. T128Telemetry.FILE
    self.bridgeReader = T128Telemetry.chooseBridgeReader()
    if self.bridgeReader ~= nil then
        print("T128Telemetry " .. T128Telemetry.VERSION .. ": idle until the T128 LED bridge reports the wheel")
    else
        print("T128Telemetry " .. T128Telemetry.VERSION .. ": this game cannot read " .. T128Telemetry.BRIDGE_FILE
              .. "; going by controller names instead: " .. T128Telemetry.listControllers())
    end
    self:setEnabled(self:isWheelAvailable())
end

function T128Telemetry:deleteMap()
    if self.path ~= nil and self.enabled then
        pcall(self.write, self, 0, 0, 0, 0, 0, 0, T128Telemetry.TURN_OFF)
    end
    if self.xml ~= nil then
        pcall(delete, self.xml)
        self.xml = nil
    end
    self.path = nil
    self.enabled = false
end

-- Every player in a multiplayer game runs this each frame, so a fault must not repeat:
-- the first error is logged and the mod stays off for the rest of the session.
function T128Telemetry:update(dt)
    if self.path == nil then
        return
    end
    local ok, err = pcall(self.step, self, dt)
    if not ok then
        print("T128Telemetry: stopped after an error: " .. tostring(err))
        self.path = nil
        self.enabled = false
    end
end

function T128Telemetry:step(dt)
    self.checkTimer = self.checkTimer + dt
    if self.checkTimer >= T128Telemetry.CHECK_INTERVAL_MS then
        self.checkTimer = 0
        self:setEnabled(self:isWheelAvailable())
    end
    if not self.enabled then
        return
    end

    self.timer = self.timer + dt
    if self.timer < T128Telemetry.WRITE_INTERVAL_MS then
        return
    end
    self.timer = 0

    local active, motorOn, rpm, minRpm, maxRpm, speed = 0, 0, 0, 0, 0, 0
    local turn = T128Telemetry.TURN_OFF

    local vehicle = T128Telemetry.getDrivenVehicle()
    local motor = vehicle ~= nil and vehicle.spec_motorized ~= nil and vehicle.spec_motorized.motor or nil
    if motor ~= nil then
        active = 1
        minRpm = motor:getMinRpm()
        maxRpm = motor:getMaxRpm()
        if vehicle.getIsMotorStarted == nil or vehicle:getIsMotorStarted() then
            motorOn = 1
            -- same value the in-game rev counter and engine sound use
            if motor.getLastModulatedMotorRpm ~= nil then
                rpm = motor:getLastModulatedMotorRpm()
            else
                rpm = motor:getLastMotorRpm()
            end
        end
        if vehicle.getLastSpeed ~= nil then
            speed = vehicle:getLastSpeed()   -- km/h
        end
        turn = T128Telemetry.getTurnState(vehicle)
    end

    self:write(active, motorOn, rpm, minRpm, maxRpm, speed, turn)
end

-- Starts or stops the file writes. Going off leaves one last "nothing to show" record
-- behind, so the bridge clears the LEDs at once instead of waiting for the file to go stale.
function T128Telemetry:setEnabled(enabled)
    if enabled == self.enabled then
        return
    end
    if self.enabled then
        self:write(0, 0, 0, 0, 0, 0, T128Telemetry.TURN_OFF)
    end
    self.enabled = enabled
    self.timer = 0
    if enabled then
        if createFolder ~= nil then
            createFolder(getUserProfileAppPath() .. "modSettings/")
            createFolder(self.folder)
        end
        print("T128Telemetry: wheel available, writing " .. self.path)
    else
        print("T128Telemetry: wheel not available, telemetry off")
    end
end

---------------------------------------------------------------------------
-- wheel availability
---------------------------------------------------------------------------
-- The bridge is the one that can see the wheel on USB, so it decides. While it runs it
-- rewrites bridge.xml with a counter ("beat") and whether it has the wheel. The mod is on
-- only while that counter keeps changing and wheel is 1. No bridge, a bridge without the
-- wheel, or a file left behind by a bridge that crashed all mean off.

-- Called once a second. @return true when telemetry should be written
function T128Telemetry:isWheelAvailable()
    if self.bridgeReader == nil then
        return T128Telemetry.isWheelListed()
    end

    local ok, beat, wheel = pcall(T128Telemetry.readBridge, self.folder .. T128Telemetry.BRIDGE_FILE, self.bridgeReader)
    if not ok then
        beat = nil
    end

    if beat == nil then
        -- The file is there but gave nothing usable. Once is normal (the bridge was
        -- replacing it); every time means this way of reading does not work here.
        self.bridgeUnreadable = self.bridgeUnreadable + 1
        if self.bridgeUnreadable >= T128Telemetry.BRIDGE_UNREADABLE_CHECKS then
            self.bridgeReader = nil
            print("T128Telemetry: cannot read " .. T128Telemetry.BRIDGE_FILE .. "; going by controller names instead: "
                  .. T128Telemetry.listControllers())
            return T128Telemetry.isWheelListed()
        end
        self.bridgeMissed = self.bridgeMissed + 1
    elseif beat == false then
        self.bridgeUnreadable = 0
        self.lastBeat = nil
        self.bridgeMissed = T128Telemetry.BRIDGE_MISSED_CHECKS
    else
        self.bridgeUnreadable = 0
        -- Only a beat seen to change counts, so a leftover file never switches the mod on.
        if self.lastBeat ~= nil and beat ~= self.lastBeat then
            self.bridgeMissed = 0
        else
            self.bridgeMissed = self.bridgeMissed + 1
        end
        self.lastBeat = beat
        self.bridgeHasWheel = wheel == 1
    end

    return self.bridgeMissed < T128Telemetry.BRIDGE_MISSED_CHECKS and self.bridgeHasWheel
end

-- The game's io.open cannot read, so bridge.xml is read with the XML functions.
-- @return a function(path) giving beat, wheel; nil if this game offers no way
function T128Telemetry.chooseBridgeReader()
    if fileExists == nil then
        return nil
    end
    if XMLFile ~= nil and XMLFile.loadIfExists ~= nil then
        return function(path)
            local xmlFile = XMLFile.loadIfExists("t128Bridge", path)
            if xmlFile == nil then
                return nil
            end
            local version, beat, wheel = xmlFile:getInt("bridge#version"), xmlFile:getInt("bridge#beat"), xmlFile:getInt("bridge#wheel")
            xmlFile:delete()
            return version, beat, wheel
        end
    end
    if loadXMLFile ~= nil and getXMLInt ~= nil and delete ~= nil then
        return function(path)
            local handle = loadXMLFile("t128Bridge", path)
            if handle == nil or handle == 0 then
                return nil
            end
            local version, beat, wheel = getXMLInt(handle, "bridge#version"), getXMLInt(handle, "bridge#beat"), getXMLInt(handle, "bridge#wheel")
            delete(handle)
            return version, beat, wheel
        end
    end
    return nil
end

-- @return beat, wheel; false when there is no file; nil when it could not be read
function T128Telemetry.readBridge(path, reader)
    if not fileExists(path) then
        return false
    end
    local version, beat, wheel = reader(path)
    if version ~= T128Telemetry.BRIDGE_FORMAT or type(beat) ~= "number" then
        return nil
    end
    return beat, wheel
end

-- Fallback only: true if any controller the game knows about looks like the wheel.
function T128Telemetry.isWheelListed()
    if getNumOfGamepads == nil or getGamepadName == nil then
        return false
    end
    for i = 0, getNumOfGamepads() - 1 do
        local name = getGamepadName(i)
        if type(name) == "string" then
            name = name:lower()
            for _, fragment in ipairs(T128Telemetry.DEVICE_NAMES) do
                if name:find(fragment, 1, true) ~= nil then
                    return true
                end
            end
        end
    end
    return false
end

function T128Telemetry.listControllers()
    if getNumOfGamepads == nil or getGamepadName == nil then
        return "(cannot be listed)"
    end
    local names = {}
    for i = 0, getNumOfGamepads() - 1 do
        names[#names + 1] = tostring(getGamepadName(i))
    end
    return #names > 0 and table.concat(names, ", ") or "(none)"
end

---------------------------------------------------------------------------
-- reading the vehicle
---------------------------------------------------------------------------

function T128Telemetry.getDrivenVehicle()
    local player = g_localPlayer
    if player ~= nil and player.getCurrentVehicle ~= nil then
        return player:getCurrentVehicle()
    end
    return nil
end

function T128Telemetry.getTurnState(vehicle)
    local spec = vehicle.spec_lights
    if spec == nil or Lights == nil then
        return T128Telemetry.TURN_OFF
    end
    local state = spec.turnLightState
    if state == Lights.TURNLIGHT_LEFT then
        return T128Telemetry.TURN_LEFT
    elseif state == Lights.TURNLIGHT_RIGHT then
        return T128Telemetry.TURN_RIGHT
    elseif state == Lights.TURNLIGHT_HAZARD then
        return T128Telemetry.TURN_HAZARD
    end
    return T128Telemetry.TURN_OFF
end

---------------------------------------------------------------------------
-- writing the telemetry file
---------------------------------------------------------------------------

-- seq changes on every write; the bridge uses it to tell live data from a stale file.
function T128Telemetry:write(active, motorOn, rpm, minRpm, maxRpm, speed, turn)
    self.seq = (self.seq + 1) % 1000000
    local values = {self.seq, active, motorOn, math.floor(rpm + 0.5), math.floor(minRpm + 0.5),
                    math.floor(maxRpm + 0.5), math.floor(speed + 0.5), turn}

    -- Plain io.open first. If the game refuses it, fall back to its XML functions; both
    -- produce the same attributes. Whichever works first is kept, so a single write that
    -- fails because the bridge was reading the file at that instant is simply skipped.
    if self.writeMethod ~= "xml" and self:writeWithIo(values) then
        self.writeMethod = "io"
    elseif self.writeMethod ~= "io" and self:writeWithXml(values) then
        self.writeMethod = "xml"
    end
end

T128Telemetry.FIELDS = {"seq", "active", "motor", "rpm", "minRpm", "maxRpm", "speed", "turn"}

function T128Telemetry:writeWithIo(values)
    if io == nil or io.open == nil then
        return false
    end
    local file = io.open(self.path, "w")
    if file == nil then
        return false
    end
    local attrs = {}
    for i, name in ipairs(T128Telemetry.FIELDS) do
        attrs[i] = string.format('%s="%d"', name, values[i])
    end
    file:write("<telemetry " .. table.concat(attrs, " ") .. "/>\n")
    file:close()
    return true
end

function T128Telemetry:writeWithXml(values)
    if createXMLFile == nil or setXMLInt == nil or saveXMLFile == nil then
        return false
    end
    if self.xml == nil then
        local xml = createXMLFile("t128Telemetry", self.path, "telemetry")
        if xml == nil or xml == 0 then
            return false
        end
        self.xml = xml
    end
    for i, name in ipairs(T128Telemetry.FIELDS) do
        setXMLInt(self.xml, "telemetry#" .. name, values[i])
    end
    saveXMLFile(self.xml)
    return true
end

addModEventListener(T128Telemetry)
