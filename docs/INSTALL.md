# Installing

Farming Simulator 25 engine RPM, turn signals and hazards on the four rev LEDs of a Thrustmaster
T128 wheel.

**This version has not been run on a real setup yet.** The LED protocol was confirmed on the
wheel with standalone tools, and the bridge and mod pass their automated tests, but the two have
not been used together with the game. See "Known rough edges" for what to expect.

## What you need

- A **Thrustmaster T128** (Xbox model, "T128X") on a Windows PC.
- The **Thrustmaster driver** for the wheel, installed. It switches the wheel into its PC mode
  when you plug it in; the LEDs only respond in that mode.
- **Farming Simulator 25** on Windows.

## Install

1. **Unzip** the download into a folder of its own, for example `C:\t128-leds`.
2. **Install the mod:** copy `FS25_T128Telemetry.zip` (leave it zipped) into
   `Documents\My Games\FarmingSimulator2025\mods`.

## Check the wheel first

With the game closed, open a command prompt in the folder and run:

```
fs25_t128_leds.exe --fake
```

It should print `Wheel connected` and then loop every 40 seconds through an RPM sweep, a right
signal, a left signal and hazards. Keep your hands off the rim the first time: LED packets share
a channel with the wheel's force feedback. Ctrl+C stops it and clears the LEDs.

## Use

1. Close Fanaleds and the Thrustmaster control panel if they are open.
2. Run **`Start T128 LEDs.bat`**. A console window opens with a status line.
3. Start FS25 and tick **T128 LED Telemetry** in the mod list when you load your savegame.
4. Get in a vehicle and start the engine. The status line should say `game driving` and
   `wheel ok`, and the LEDs follow the engine.

It does not matter whether you start the bridge or the game first. To stop, close the console
window or press Ctrl+C in it.

## What the LEDs show

| In the game | LEDs |
|---|---|
| Engine running at low RPM | First LED blinks slowly |
| Engine RPM | 1 / 2 / 3 / 4 LEDs at 55 / 68 / 80 / 92% of the vehicle's max RPM |
| RPM at 95% of max or more | All four flash |
| Right turn signal | Bar fills left to right |
| Left turn signal | Bar drains right to left |
| Hazards | All four blink |
| Engine off, on foot, paused, or game closed | Off |

Tractors spend a lot of time near max RPM. If the flashing gets tiresome, edit
`Start T128 LEDs.bat` and change the line `fs25_t128_leds.exe %*` to
`fs25_t128_leds.exe --no-flash %*`; the bar then stops at four LEDs. `--no-idle-blink` in the
same place turns off the slow blink at low RPM.

## If it does not work

- **`wheel missing`:** the bridge found no wheel in PC mode. Check the Thrustmaster driver is
  installed and the wheel shows up in Windows as "Thrustmaster Advance Racer".
- **`game waiting` together with `wheel missing`:** expected. The mod stays off until the bridge
  has the wheel.
- **`game waiting` with `wheel ok`:** the mod is not writing. Check it is ticked for the savegame
  and that the game is not paused, then look for lines starting `T128Telemetry` in
  `Documents\My Games\FarmingSimulator2025\log.txt`. It prints
  `idle until the T128 LED bridge reports the wheel` when the savegame loads and
  `wheel available, writing ...` a second or two after the bridge finds the wheel. If it stays
  idle, please report it along with those log lines.
- **`wheel ok` but the LEDs stay dark while the game runs:** the wheel may not accept LED data
  while the game is using it. This is the main untested point; please report it.

## What it changes on your PC

- The bridge sends LED data to the wheel only while it runs. It writes no setting to the wheel
  and installs nothing.
- While it runs, the bridge keeps a small file, `bridge.xml`, in
  `modSettings\FS25_T128Telemetry` in your FS25 profile to tell the mod it has the wheel. It
  deletes the file when it closes.
- The mod writes `telemetry.xml` in the same folder, and only while the bridge is running with
  the wheel connected. It changes nothing in the game itself.

## Multiplayer

Everyone who joins a game needs the same mods the host has active, as identical files, so the
other players need this `FS25_T128Telemetry.zip` too. They do not need the bridge or a wheel.
Without the bridge the mod does nothing on their PC: it writes no file and does not touch the
game. Multiplayer is untested.

## Uninstall

Delete the folder, and delete `FS25_T128Telemetry.zip` from the FS25 mods folder. Nothing else is
installed.

## Known rough edges

- Not yet run in the game or against the wheel as a whole (see the top of this page).
- The RPM thresholds were chosen on the bench and will probably want tuning for tractors.
- The wheel's firmware only draws a bar starting from the left LED, so a left signal cannot light
  just the left LEDs.
- The bridge and the mod must be the same version: 0.1.0 of either does not work with 0.1.1 of
  the other.
