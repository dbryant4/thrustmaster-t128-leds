# Farming Simulator → wheel/yoke bridge

## Goal
One Windows app that reads Farming Simulator 25 telemetry and drives:
1. **MOZA flight yoke force feedback** via the MOZA SDK (yoke roll axis used as steering).
2. **Thrustmaster T128 (Xbox model) rev LEDs**: RPM bar, turn signals, hazards.

Hardware: MOZA FFB yoke base (model TBD; put the SDK in `./sdk/`), Thrustmaster T128X,
a Windows PC (game + devices) and a Mac (dev/probing).

## Architecture
- `fs-mod/`: FS25 Lua mod. Each tick, read speed, engine RPM, max RPM, steering angle, wheel load/slip,
  ground type, implement lowered, turn signal state, hazards. Write to a small file in `modSettings/`
  at 30–60 Hz (the Lua sandbox has no sockets).
- `bridge/`: Windows app. Poll telemetry; output stage 1 = MOZA FFB, output stage 2 = T128 LEDs.

## MOZA force feedback model
- Spring: centering stiffness scales with speed (~0 when stopped)
- Damper: weight, more with heavy implements
- Constant force: self-aligning pull / loader or trailer drag
- Sine: rumble on rough fields, gravel, while working ground
- Build order: fixed spring+damper MVP (no mod) → speed-scaled centering → rumble/load
- Risks: MOZA Cockpit telemetry FFB conflicting with SDK effects; FS25 grabbing the device for DirectInput FFB

## T128 LED protocol (reverse-engineered, verified on hardware)

### Modes
- Boots as Xbox GIP device `044f:b69c` (vendor class, not HID). GIP probing found no LED path.
- On Windows the Thrustmaster driver switches modes automatically. Manually (pyusb/libusb):
  vendor control OUT `bmRequestType=0x41 bRequest=0x53 wValue=0x000b wIndex=0 len=0`.
  The wheel re-enumerates as HID `044f:b696` "Thrustmaster Advance Racer" and runs its calibration sweep.
- Read-only queries: `0xC1/0x49` len 16 (model), `0xC1/0x56` len 8 (firmware).
- **Never send `01 04` on report 0x0a**: it resets the wheel back to GIP mode.

### Transport (host → wheel, 64-byte interrupt OUT, first byte 0x60)
- On Windows, `WriteFile` on the HID handle with a 64-byte buffer starting `0x60` works
  (even though the HID descriptor only declares output report 0x0a).
- Packet: `60 00 <sub-commands...>`, zero-padded to 64.
  - `01 89 01` / `01 8a <i16> 01`: force feedback (play / constant force), seen from the driver.
  - `42 <n> <n bytes>`: a chunk of a framed message stream. Frames ≤10 bytes go whole; longer ones in 8-byte chunks.
- Frame: `d0 63 | len u16 LE (whole frame) | crc u16 LE | payload`
  - CRC: reflected CRC-16, init 0: `c ^= b; repeat 8: c = (c & 1) ? (c >> 1) ^ 0x8005 : c >> 1`,
    over the frame with the crc field removed. Verified against all 143 captured frames.
  - Test vectors: empty payload → `d0 63 06 00 e6 b8`; payload `54 08 bf 02` → `d0 63 0a 00 fc 89 54 08 bf 02`.

### Payloads
| Payload | Use |
|---|---|
| empty | keepalive, every ~450 ms |
| `21` | send once before telemetry starts |
| `1f 01 f4 65 00 0a 71 02 00 02 25 7a 35 e5 03` | config blob the driver sent ~5x before start (replayed as-is) |
| `54 08 <u16 LE value>` | telemetry, 10–20 Hz. First field (0x0854 = 2132) was constant in the capture; value drives the LEDs |

### LED thresholds (first field = 2132), measured
| LEDs | value |
|---|---|
| 1 | 460 |
| 2 | 590 |
| 3 | 710 |
| 4 | 820 |
| all flash (firmware) | 920 |

Safe in-band values used: 0, 520, 650, 765, 870, 960.
Open question: whether the first field is max RPM (would rescale thresholds). The tuner's M key tests 1066/4264.

### Limits
- The firmware draws a bar from LED 1 upward; no per-LED control found. Fanaleds doesn't support the T128.

### Behaviour (validated in `t128-c/t128_signals_demo.c`)
- RPM: 1/2/3/4 LEDs at 55/68/80/92% of max RPM; firmware flash at ≥95%.
- Idle (bridge only, not in the demo, not yet seen on hardware): engine running below 55% blinks LED 1, 1 s on / 1 s off.
- Right signal: 1→2→3→4→off, 130 ms steps (moves left→right).
- Left signal: 4→3→2→1→off (bar drains right→left).
- Hazards: all on/off, 380 ms half-period.
- Signals override RPM.

## Repo contents
- `t128-c/`: Windows C tools. Build with mingw:
  `x86_64-w64-mingw32-gcc -O2 -static file.c -o file.exe -lhid -lsetupapi`.
  `t128_signals_demo.c` is the reference LED driver to port into `bridge/`.
- `tools/`: Mac/Linux probes (pyusb/hidapi scripts, WebHID page) used during reverse engineering.
- `bridge/` (v0.1.1, LED stage only, C): `fs25_t128_leds.c` polls the mod's file and drives the LEDs;
  `t128_hid.h` is the Windows HID side, `t128_logic.h` the portable framing/parser/LED logic.
  `--fake` plays a built-in telemetry loop. Tests: `cc bridge/test_logic.c -o /tmp/t && /tmp/t`.
- `fs-mod/FS25_T128Telemetry/` (v0.1.1): writes `modSettings/FS25_T128Telemetry/telemetry.xml` at 20 Hz via
  `io.open` (fallback `createXMLFile`/`saveXMLFile`): `<telemetry seq active motor rpm minRpm maxRpm speed turn/>`
  (turn: 0 off, 1 left, 2 right, 3 hazard). Must stay inert for players without the wheel
  (every multiplayer player loads the mod): it is on only while the bridge's heartbeat `bridge.xml`
  (`<bridge version="1" beat wheel/>`, rewritten every 500 ms, read once a second with the XML functions)
  keeps changing and says `wheel="1"`. Controller-name matching (`DEVICE_NAMES`) is only the fallback
  when `bridge.xml` cannot be read. Mock test: `lua fs-mod/tests/run_mock.lua /tmp/fs25-mock`.
- Release: `scripts/package-release.sh` builds `dist/thrustmaster-t128-leds-<version>-windows.zip` (bridge exe,
  launcher, mod zip, `docs/INSTALL.md`, licence). Version lives in three places that must agree:
  `VERSION` in `bridge/fs25_t128_leds.c`, `modDesc.xml` and `T128Telemetry.VERSION` (four-part form).
- The MOZA force feedback side lives in its own repo, `~/projects/moza-farmsim-link` (github.com/dbryant4/moza-farmsim-link).
  Its mod is game-tested on FS25 1.24; check it for FS25 Lua API usage before guessing.
- Neither the bridge nor the mod has been run on the wheel / in the game yet.

## Next tasks
1. Run the LED bridge + mod on the real setup (does the wheel accept LED packets while FS25 has it open?).
2. Read `./sdk/` (MOZA) and pick C++ or C#; port the bridge into the same language.
3. MOZA fixed spring+damper MVP; extend the mod with steering angle, wheel load/slip, ground type, implement state.
4. Tune the FFB model and LED thresholds in-game.
