# Farming Simulator 25 → Thrustmaster T128 rev LEDs

**Version 0.1.0**

Shows Farming Simulator 25 engine RPM, turn signals and hazards on the four rev LEDs of a
Thrustmaster T128 (Xbox model). The wheel has no documented LED API and Fanaleds does not
support it, so the LED protocol here was reverse-engineered from a capture of the Thrustmaster
Windows driver.

The longer-term goal is one Windows app that also drives force feedback on a MOZA flight yoke
used as a steering wheel. That part has not been started.

## Status

| Part | State |
|---|---|
| T128 LED protocol | Decoded and confirmed on the wheel with the tools in `t128-c/` |
| LED bridge (`bridge/`) | Written, builds, logic unit-tested. **Not yet run against the wheel** |
| FS25 telemetry mod (`fs-mod/`) | Written, tested against a mock of the game API. **Not yet run in the game** |
| MOZA force feedback | Not started (needs the MOZA SDK in `./sdk/`) |

The first real run should answer two open questions: whether the wheel accepts LED packets
while FS25 has it open for input and force feedback (the earlier tools were only run with
games closed), and whether the mod loads cleanly in your game version.

## What the LEDs do

| Game state | LEDs |
|---|---|
| Engine RPM | 1 / 2 / 3 / 4 LEDs at 55 / 68 / 80 / 92% of the vehicle's max RPM |
| RPM ≥ 95% of max | All four flash (done by the wheel firmware). `--no-flash` holds 4 LEDs instead |
| Right turn signal | Bar fills left → right: 1, 2, 3, 4, off, 130 ms per step |
| Left turn signal | Bar drains right → left: 4, 3, 2, 1, off |
| Hazards | All four blink, 380 ms on / 380 ms off |
| On foot, game paused or closed | Off |

The mod only runs while the game sees a Thrustmaster wheel. It looks at the game's controller
list every 2 seconds; with no wheel it writes nothing, and it starts again by itself when the
wheel is plugged in.

Signals override RPM. The firmware only draws a bar starting from LED 1, so there is no
per-LED control and a left signal can't light the left LEDs only.

## Setup

You need a Windows PC with the Thrustmaster driver installed (it switches the wheel from Xbox
mode to PC mode when the wheel is plugged in) and Farming Simulator 25.

1. **Install the mod.** Copy the `fs-mod/FS25_T128Telemetry` folder into
   `Documents\My Games\FarmingSimulator2025\mods\` and enable *T128 LED Telemetry* when you
   load your savegame.
2. **Test the wheel on its own.** Build `bridge/fs25_t128_leds.exe` (see
   [Building and testing](#building-and-testing); it is not checked in), copy it to the PC and
   run it with the game closed:

   ```
   fs25_t128_leds.exe --fake
   ```

   It should print `Wheel connected` and loop through an RPM sweep, right signal, left signal
   and hazards every 40 seconds.
3. **Run it with the game.** Start `fs25_t128_leds.exe` with no arguments, before or after the
   game. The status line shows what it sees:

   ```
   game driving wheel ok      rpm 1450/2200   17 km/h  signal LEFT   LEDs ###.
   ```

   `game waiting` means the telemetry file is missing or not changing, which includes the mod
   having switched itself off because the game sees no Thrustmaster wheel. `wheel missing`
   means no `044f:b696` device accepted a packet. Both recover on their own when the game or
   wheel comes back. Ctrl+C clears the LEDs and exits.

Options:

| Option | Effect |
|---|---|
| `--fake` | Ignore the game and play the built-in loop |
| `--no-flash` | Cap the RPM bar at 4 LEDs. Useful because tractors spend a lot of time near max RPM |
| `--file PATH` | Read telemetry from another path. The default is `Documents\My Games\FarmingSimulator2025\modSettings\FS25_T128Telemetry\telemetry.xml` |

If the mod does not appear in the game or `game waiting` never clears, look in
`Documents\My Games\FarmingSimulator2025\log.txt` for lines mentioning `T128Telemetry`:

- `game controllers: ...` lists the controller names the game reports, followed by either
  `wheel found, writing <path>` or `no Thrustmaster wheel connected, telemetry off`.
- If the wheel is plugged in but the mod says it is not, the game is calling it something
  unexpected. Add a lower-case piece of the listed name to `DEVICE_NAMES` at the top of
  `T128Telemetry.lua` (it matches `thrustmaster`, `t128` and `advance racer` by default).
- A `descVersion` complaint means the value in `modDesc.xml` (currently 92) needs changing to
  match your game version.

## How it works

```
FS25 (Lua mod) ──► telemetry.xml ──► fs25_t128_leds.exe ──► T128 HID (0x60 packets) ──► LEDs
                   20 writes/s        polls 20 times/s
```

FS25 mod scripts cannot open sockets or talk to USB devices, so the mod rewrites a one-line
XML file through the game's own XML functions, and detects the wheel by name from the game's
controller list:

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
| `fs-mod/FS25_T128Telemetry/` | The FS25 mod (`modDesc.xml`, `T128Telemetry.lua`, icon) |
| `fs-mod/test/run_mock.lua` | Runs the mod against stubs of the game functions it calls |
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

The Windows programs cross-compile from macOS or Linux with mingw-w64:

```bash
x86_64-w64-mingw32-gcc -O2 -static bridge/fs25_t128_leds.c -o bridge/fs25_t128_leds.exe -lhid -lsetupapi
```

```bash
x86_64-w64-mingw32-gcc -O2 -static t128-c/t128_signals_demo.c -o t128_signals_demo.exe -lhid -lsetupapi
```

Tests that need neither Windows nor the wheel:

```bash
cc bridge/test_logic.c -o /tmp/test_logic && /tmp/test_logic
```

```bash
lua fs-mod/test/run_mock.lua /tmp/fs25-mock
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

- The bridge and mod have not been run on real hardware or in the game yet (see Status).
- LED thresholds are percentages of max RPM, chosen on the bench. They will likely need
  tuning for tractors; the constants are `RPM_LED_ON` in `bridge/t128_logic.h`.
- It is unknown whether the first telemetry field (`0x0854` = 2132) is a max-RPM value. If it
  is, the thresholds above rescale with it.
- Signal animation steps land on the bridge's 50 ms tick, so a 130 ms step is really 100–150 ms.
- The mod recognises the wheel by its controller name, and that name has not been checked in
  the game yet. A different Thrustmaster device (pedals, shifter, joystick) also counts as a
  match.
- The mod icon is a generated placeholder.
- The bridge is plain C for now. `CLAUDE.md` plans to pick C++ or C# once the MOZA SDK is in
  `./sdk/`, and port the LED code to match.

## Roadmap

1. Run the bridge and mod on the real setup; tune thresholds in-game.
2. Add the MOZA SDK and build the force feedback stage (fixed spring and damper first, then
   speed-scaled centering, then rumble and load).
3. Extend the mod with the extra fields force feedback needs: steering angle, wheel load and
   slip, ground type, implement state.

This is a personal project and is not affiliated with Thrustmaster, MOZA or GIANTS Software.
