#!/usr/bin/env python3
"""T128 rev-LED test using the telemetry protocol decoded from the Windows capture.

Wire format (host -> wheel, interrupt OUT, 64 bytes):
  60 00 42 <n> <frame, n bytes> 00...
Frame:
  d0 63 | len u16 LE (whole frame) | crc u16 LE | payload
  crc = reflected CRC-16, constant 0x8005, init 0, over frame minus the crc field
Payloads seen from the driver:
  (empty)                          keepalive, ~every 0.45 s
  21                               sent once right before telemetry starts
  54 08 <u16>                      telemetry, ~10 Hz; 0x0854 constant, u16 varied 0-703
  1f 01 f4 65 00 0a 71 02 ...      config blob, repeated before the game started

Wheel must be in PC HID mode (044f:b696): run tm_mode_switch.py first.
Requires: pip install hidapi
"""
import time, struct
import hid

VID, PID = 0x044F, 0xB696
CONFIG = bytes.fromhex("1f01f465000a71020002257a35e503")

def crc16(data):
    c = 0
    for b in data:
        c ^= b
        for _ in range(8):
            c = (c >> 1) ^ 0x8005 if c & 1 else c >> 1
    return c

def frame(payload=b""):
    n = 6 + len(payload)
    head = b"\xd0\x63" + struct.pack("<H", n)
    return head + struct.pack("<H", crc16(head + payload)) + payload

# Self-test against frames captured from the Windows driver
assert frame() == bytes.fromhex("d0630600e6b8")
assert frame(bytes.fromhex("5408bf02")) == bytes.fromhex("d0630a00fc895408bf02")
assert frame(b"\x21") == bytes.fromhex("d0630700715521")
assert frame(CONFIG) == bytes.fromhex("d0631500392e1f01f465000a71020002257a35e503")

dev = hid.device()
dev.open(VID, PID)
print("Opened", dev.get_product_string())

def send(fr):
    # Match the driver: frames up to 10 bytes go whole, longer ones in 8-byte chunks
    size = len(fr) if len(fr) <= 10 else 8
    for i in range(0, len(fr), size):
        chunk = fr[i:i + size]
        pkt = bytes([0x60, 0x00, 0x42, len(chunk)]) + chunk
        dev.write(list(pkt.ljust(64, b"\x00")))

last_keepalive = 0.0
def tick():
    global last_keepalive
    if time.time() - last_keepalive > 0.45:
        send(frame()); last_keepalive = time.time()

def telemetry(value, a=0x54, b=0x08):
    send(frame(bytes([a, b]) + struct.pack("<H", value)))

def hold(seconds, value, **kw):
    end = time.time() + seconds
    while time.time() < end:
        tick(); telemetry(value, **kw); time.sleep(0.1)

print("Sending config + start, as the driver did")
for _ in range(5):
    tick(); send(frame(CONFIG)); time.sleep(0.09)
send(frame(b"\x21")); time.sleep(0.05)

print("\nPhase 1: replay the highest captured value (703) for 4 s")
hold(4, 703)

print("\nPhase 2: sweep 0 -> 2132 over ~10 s. Note the value when each LED lights.")
for v in range(0, 2133, 20):
    print(f"\r  value {v:5d}", end="", flush=True)
    tick(); telemetry(v); time.sleep(0.1)
print()
hold(3, 2132)

print("\nPhase 3: sweep the first byte instead (in case 0x54 is the value)")
for a in range(0, 256, 8):
    print(f"\r  byte {a:3d}", end="", flush=True)
    tick(); telemetry(0, a=a, b=0x08); time.sleep(0.15)
print()

print("\nPhase 4: back to 0")
hold(2, 0)
dev.close()
print("Done. Tell Claude what lit up, and at which values.")
