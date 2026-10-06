-- T128Telemetry: writes the driven vehicle's engine RPM and turn-signal state to
-- <profile>/modSettings/FS25_T128Telemetry/telemetry.xml about 20 times a second.
-- The Windows bridge (bridge/fs25_t128_leds.c) polls that file and drives the wheel LEDs.
-- Mod scripts have no sockets, so a small file is the only way out of the game.
-- The mod switches itself off (no file writes) while the game sees no Thrustmaster wheel.

T128Telemetry = {}

T128Telemetry.WRITE_INTERVAL_MS = 50
T128Telemetry.FOLDER = "modSettings/FS25_T128Telemetry/"
T128Telemetry.FILE = "telemetry.xml"

-- How often to look for the wheel, and lower-case fragments of the controller names
-- that count as one. The names the game reports are printed to log.txt on load.
T128Telemetry.DEVICE_CHECK_INTERVAL_MS = 2000
T128Telemetry.DEVICE_NAMES = {"thrustmaster", "t128", "advance racer"}

-- Values written to the "turn" attribute. Kept separate from the game's own
-- Lights.TURNLIGHT_* numbers so the bridge does not depend on them.
T128Telemetry.TURN_OFF = 0
T128Telemetry.TURN_LEFT = 1
T128Telemetry.TURN_RIGHT = 2
T128Telemetry.TURN_HAZARD = 3

function T128Telemetry:loadMap()
    self.timer = 0
    self.deviceTimer = 0
    self.seq = 0
    self.xml = nil
    self.enabled = nil

    if g_dedicatedServerInfo ~= nil then
        return
    end

    local profile = getUserProfileAppPath()
    createFolder(profile .. "modSettings/")
    createFolder(profile .. T128Telemetry.FOLDER)

    local path = profile .. T128Telemetry.FOLDER .. T128Telemetry.FILE
    local xml = createXMLFile("t128Telemetry", path, "telemetry")
    if xml == nil or xml == 0 then
        print("T128Telemetry: could not create " .. path)
        return
    end
    self.xml = xml
    self.path = path
    print("T128Telemetry: game controllers: " .. T128Telemetry.listControllers())
    self:setEnabled(T128Telemetry.isWheelConnected())
end

function T128Telemetry:deleteMap()
    if self.xml ~= nil then
        if self.enabled then
            self:write(0, 0, 0, 0, 0, 0, T128Telemetry.TURN_OFF)
        end
        delete(self.xml)
        self.xml = nil
    end
end

function T128Telemetry:update(dt)
    if self.xml == nil then
        return
    end

    self.deviceTimer = self.deviceTimer + dt
    if self.deviceTimer >= T128Telemetry.DEVICE_CHECK_INTERVAL_MS then
        self.deviceTimer = 0
        self:setEnabled(T128Telemetry.isWheelConnected())
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
        print("T128Telemetry: wheel found, writing " .. self.path)
    else
        print("T128Telemetry: no Thrustmaster wheel connected, telemetry off")
    end
end

-- True if any controller the game knows about looks like the wheel. If the engine
-- cannot list controllers at all, assume it is there rather than never working.
function T128Telemetry.isWheelConnected()
    if getNumOfGamepads == nil or getGamepadName == nil then
        return true
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

-- seq changes on every write; the bridge uses it to tell live data from a stale file.
function T128Telemetry:write(active, motorOn, rpm, minRpm, maxRpm, speed, turn)
    local xml = self.xml
    self.seq = (self.seq + 1) % 1000000
    setXMLInt(xml, "telemetry#seq", self.seq)
    setXMLInt(xml, "telemetry#active", active)
    setXMLInt(xml, "telemetry#motor", motorOn)
    setXMLInt(xml, "telemetry#rpm", math.floor(rpm + 0.5))
    setXMLInt(xml, "telemetry#minRpm", math.floor(minRpm + 0.5))
    setXMLInt(xml, "telemetry#maxRpm", math.floor(maxRpm + 0.5))
    setXMLInt(xml, "telemetry#speed", math.floor(speed + 0.5))
    setXMLInt(xml, "telemetry#turn", turn)
    saveXMLFile(xml)
end

addModEventListener(T128Telemetry)
