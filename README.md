# Farming Simulator 25 → Thrustmaster T128 rev LEDs

**Version 0.1.2**

Shows Farming Simulator 25 engine RPM, turn signals and hazards on the four rev LEDs of a
Thrustmaster T128 (Xbox model). The wheel has no documented LED API and Fanaleds does not
support it, so the LED protocol here was reverse-engineered from a capture of the Thrustmaster
Windows driver.

Its sister project, [moza-farmsim-link](https://github.com/dbryant4/moza-farmsim-link), does
force feedback for FS25 on a MOZA flight yoke. The two are independent of each other.

**Download:** the [latest release](https://github.com/dbryant4/thrustmaster-t128-leds/releases/latest) has one Windows zip with
the bridge, its launcher, the FS25 mod and the [install guide](docs/INSTALL.md).

## Status

| Part | State |
|---|---|
| T128 LED protocol | Decoded and confirmed on the wheel with the tools in `t128-c/` |
| LED bridge (`bridge/`) | Runs against the wheel while FS25 is using it (first seen with 0.1.1). Logic unit-tested |
| FS25 telemetry mod (`fs-mod/`) | Loads in the game and finds the bridge (first seen with 0.1.1). Tested against a mock of the game API |

Seen working in the game so far: the idle blink. The RPM bar, turn signals and hazards use the
same path but have not been confirmed in the game yet, and multiplayer is untested.

## What the LEDs do

| Game state | LEDs |
|---|---|
| Engine running, RPM below the bar's first step | First LED blinks, 0.5 s on / 0.5 s off. `--idle-blink-ms` changes the rate, `--no-idle-blink` keeps it dark |
| Engine RPM | 1 / 2 / 3 / 4 LEDs at 25 / 45 / 65 / 85% of the way from the vehicle's idle RPM to its max RPM |
| RPM ≥ 95% of the way to max | All four flash (done by the wheel firmware). `--no-flash` holds 4 LEDs instead |
| Right turn signal | Bar fills left → right: 1, 2, 3, 4, off, 130 ms per step |
| Left turn signal | Bar drains right → left: 4, 3, 2, 1, off |
| Hazards | All four blink, 380 ms on / 380 ms off |
| Engine off, on foot, game paused or closed | Off |

The mod does nothing unless the bridge is running on the same PC and has the wheel. That
matters in multiplayer, where every player has to load the mod: for players without the wheel
it writes no file, creates no folder and never queries the vehicle. It switches on within a
couple of seconds of the bridge finding the wheel, and off again when the wheel is unplugged
or the bridge closes.

Signals override RPM. The firmware only draws a bar starting from LED 1, so there is no
per-LED control and a left signal can't light the left LEDs only.

## Setup

You need a Windows PC with the Thrustmaster driver installed (it switches the wheel from Xbox
mode to PC mode when the wheel is plugged in) and Farming Simulator 25.

Download and unzip the [latest release](https://github.com/dbryant4/thrustmaster-t128-leds/releases/latest), or build it
yourself (see [Building and testing](#building-and-testing)). [docs/INSTALL.md](docs/INSTALL.md)
is the full guide; in short:

1. **Install the mod.** Copy `FS25_T128Telemetry.zip`, still zipped, into
   `Documents\My Games\FarmingSimulator2025\mods\` and enable *T128 LED Telemetry* when you
   load your savegame.
2. **Test the wheel on its own.** Run the bridge with the game closed:

   ```
   fs25_t128_leds.exe --fake
   ```

   It should print `Wheel connected` and loop through an RPM sweep, right signal, left signal
   and hazards every 40 seconds.
3. **Run it with the game.** Start `Start T128 LEDs.bat` (or `fs25_t128_leds.exe` with no
   arguments), before or after the game. The status line shows what it sees:

   ```
   game driving wheel ok      rpm 1450/2200   17 km/h  signal LEFT   LEDs ###.
   ```

   `wheel missing` means no `044f:b696` device accepted a packet. `game waiting` means the
   telemetry file is missing or not changing: the game is closed or paused, the mod is not
   loaded, or the wheel is missing (the mod stays off without it). Both recover on their own
   when the game or wheel comes back. Ctrl+C clears the LEDs and exits.

Options:

| Option | Effect |
|---|---|
| `--fake` | Ignore the game and play the built-in loop |
| `--no-flash` | Cap the RPM bar at 4 LEDs. Useful because tractors spend a lot of time near max RPM |
| `--idle-blink-ms N` | How long the first LED stays on, then off, while the engine idles. 100 to 5000, default 500 |
| `--no-idle-blink` | Keep the LEDs dark at low RPM instead of blinking the first one |
| `--file PATH` | Read telemetry from another path. The default is `Documents\My Games\FarmingSimulator2025\modSettings\FS25_T128Telemetry\telemetry.xml` |

If the mod does not appear in the game or `game waiting` never clears, look in
`Documents\My Games\FarmingSimulator2025\log.txt` for lines mentioning `T128Telemetry`:

- `idle until the T128 LED bridge reports the wheel` is printed when the savegame loads,
  then `wheel available, writing <path>` once the bridge is running with the wheel, and
  `wheel not available, telemetry off` when it goes away.
- If it stays idle while the bridge shows `wheel ok`, the mod is not seeing the bridge's
  `bridge.xml`. Check that the bridge and the game use the same folder (`--file` moves both).
- `going by controller names instead` means this game version could not read `bridge.xml`.
  The mod then looks for a controller whose name contains `thrustmaster`, `t128` or
  `advance racer` (`DEVICE_NAMES` at the top of `T128Telemetry.lua`).
- A `descVersion` complaint means the value in `modDesc.xml` (currently 111, which FS25 1.24
  accepts) is newer than your game; update the game or lower the value.

## How it works

```
FS25 (Lua mod) ──► telemetry.xml ──► fs25_t128_leds.exe ──► T128 HID (0x60 packets) ──► LEDs
       ▲           20 writes/s        polls 20 times/s
       └────────── bridge.xml ◄────── "running, wheel connected", twice a second
```

FS25 mod scripts cannot open sockets or talk to USB devices, so the two sides talk through
two small files in `modSettings\FS25_T128Telemetry`.

The bridge can see the wheel on USB and the mod cannot, so the bridge tells the mod whether
there is anything to do. While it runs it rewrites `bridge.xml`:

```xml
<bridge version="1" beat="42" wheel="1"/>
```

The mod reads it once a second and is on only while `beat` keeps changing and `wheel` is 1.
No file, a file left behind by a crashed bridge, or `wheel="0"` all mean off. The bridge
deletes the file when it exits.

While it is on, the mod rewrites a one-line telemetry file (with `io.open`, falling back to
the game's XML functions if that is refused):

```xml
<telemetry seq="9" active="1" motor="1" rpm="1450" minRpm="850" maxRpm="2200" speed="17" turn="2"/>
```

| Field | Meaning |
|---|---|
| `seq` | Changes on every write. If it stops changing for 1.5 s the bridge turns the LEDs off |
| `active` | 1 while you are in a motorized vehicle |
| `motor` | 1 while the engine is running |
| `rpm`, `minRpm`, `maxRpm` | Engine speed and the vehicle's limits |
| `speed` | km/h |
| `turn` | 0 off, 1 left, 2 right, 3 hazards |

## Repository layout

| Path | Contents |
|---|---|
| `bridge/fs25_t128_leds.c` | The bridge: file polling, reconnect, status line |
| `bridge/t128_hid.h` | Windows HID: finds the wheel, sends packets, keepalive |
| `bridge/t128_logic.h` | Portable: framing and CRC, telemetry parser, RPM and signal logic |
| `bridge/test_logic.c` | Unit tests for `t128_logic.h`, run on any OS |
| `bridge/windows/` | The launcher batch file shipped in the release |
| `fs-mod/FS25_T128Telemetry/` | The FS25 mod (`modDesc.xml`, `T128Telemetry.lua`, icon) |
| `fs-mod/tests/run_mock.lua` | Runs the mod against stubs of the game functions it calls |
| `fs-mod/package.sh` | Tests the mod and zips it the way FS25 expects |
| `scripts/package-release.sh` | Builds the release zip into `dist/` |
| `docs/INSTALL.md` | Install guide, also shipped in the release |
| `t128-c/` | Standalone Windows tools from the reverse engineering (below) |
| `tools/` | Mac/Linux probes from the reverse engineering (below) |
| `CLAUDE.md` | Full protocol notes, force feedback plan and task list |

### Reverse-engineering tools

| Tool | Purpose |
|---|---|
| `t128-c/t128_signals_demo.c` | Keyboard-driven RPM bar and signals. The reference the bridge was ported from |
| `t128-c/t128_led_tuner.c` | Step the telemetry value by hand and mark where each LED lights |
| `t128-c/t128_led_test.c` | First replay of the captured protocol: value sweep, then a first-byte sweep |
| `tools/tm_mode_switch.py` | pyusb: query model/firmware and switch the wheel from Xbox mode to PC HID mode |
| `tools/t128_led_test.py` | hidapi version of the LED test, for a wheel already in PC mode |
| `tools/gip_probe.py`, `tools/gip_led_probe.py` | Xbox GIP handshake and LED message probes. These found no LED path |
| `tools/t128-probe.html` | WebHID page that dumps the HID layout and sends raw reports |

The LED mask controls in `t128-probe.html` are based on an early guess (`00 41 <cmd>` on
report `0x0a`) that turned out not to be how this wheel works. Use the page for inspecting
reports, not for driving LEDs.

## Building and testing

The Windows programs cross-compile from macOS or Linux with mingw-w64 (`brew install mingw-w64`).
To run the tests, build the bridge and the mod, and assemble the release zip in one step:

```bash
scripts/package-release.sh
```

That needs mingw-w64, a host C compiler, `lua` and `zip`, and refuses to build if the bridge
and mod version numbers differ. To build pieces by hand:

```bash
x86_64-w64-mingw32-gcc -O2 -static bridge/fs25_t128_leds.c -o fs25_t128_leds.exe -lhid -lsetupapi
```

```bash
x86_64-w64-mingw32-gcc -O2 -static t128-c/t128_signals_demo.c -o t128_signals_demo.exe -lhid -lsetupapi
```

Tests that need neither Windows nor the wheel:

```bash
cc bridge/test_logic.c -o /tmp/test_logic && /tmp/test_logic
```

```bash
lua fs-mod/tests/run_mock.lua /tmp/fs25-mock
```

The Python probes need `pip install pyusb` (`tm_mode_switch.py`, `gip_*.py`) or
`pip install hidapi` (`t128_led_test.py`).

## Protocol summary

`CLAUDE.md` has the full notes. The short version:

- The wheel boots as an Xbox GIP device, `044f:b69c`. The vendor control request
  `0x41 / 0x53` with `wValue = 0x000b` switches it to PC HID mode, `044f:b696`
  "Thrustmaster Advance Racer". The Windows driver does this for you.
- LED data goes out as 64-byte reports starting `60 00`, followed by `42 <n> <n bytes>`
  chunks of a framed stream.
- Frame: `d0 63 | length u16 LE | crc u16 LE | payload`. The CRC is a reflected CRC-16
  (constant `0x8005`, init 0) over the frame without its CRC field.
- Payloads: empty = keepalive every ~450 ms; `21` = start; `54 08 <u16>` = telemetry at
  10–20 Hz. The u16 lights the LEDs:

  | LEDs | 1 | 2 | 3 | 4 | flash |
  |---|---|---|---|---|---|
  | value ≥ | 460 | 590 | 710 | 820 | 920 |

## Safety

- Keep your hands off the rim when running any probe or test. LED packets share a channel
  with force feedback commands.
- Never send `01 04` on report `0x0a`. It drops the wheel back to Xbox mode.
- Close Fanaleds and the Thrustmaster control panel before running the bridge or tools.

## Known limitations

- Only the idle blink has been confirmed in the game so far (see Status).
- The bar's steps are fixed points between each vehicle's idle and max RPM as the game reports
  them. They may still want tuning; the constants are `RPM_LED_ON` in `bridge/t128_logic.h`.
- It is unknown whether the first telemetry field (`0x0854` = 2132) is a max-RPM value. If it
  is, the thresholds above rescale with it.
- Signal animation steps land on the bridge's 50 ms tick, so a 130 ms step is really 100–150 ms.
- Multiplayer is untested. The mod is built to be inert for players without the wheel, but
  that has only been checked against a mock of the game.
- If a bridge crashes, the mod keeps writing for up to four seconds before it notices.
- The mod icon is a generated placeholder.

## Roadmap

1. Confirm the RPM bar, signals and hazards in the game; tune the bar's steps.
2. Find out whether the first telemetry field rescales the LED thresholds.
3. Fix the review findings in the `t128-c/` tools (device matching by product ID, shared header).

## Licence

MIT, see [LICENSE](LICENSE). This is a personal project and is not affiliated with Thrustmaster,
MOZA or GIANTS Software.
