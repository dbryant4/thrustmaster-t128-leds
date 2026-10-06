#!/usr/bin/env python3
"""Interactive LED probe for the Thrustmaster T128X (044f:b69c).

Does the same GIP handshake as gip_probe.py, then sends candidate LED messages
one at a time and asks what you saw. Results go to gip_led_log.txt.
Keep hands off the rim: unknown messages could be force feedback.
"""
import time, threading
import usb.core, usb.util

VID, PID = 0x044F, 0xB69C
EP_OUT, EP_IN = 0x01, 0x81
OPT_ACK, OPT_INTERNAL, OPT_CHUNK_START, OPT_CHUNK = 0x10, 0x20, 0x40, 0x80

log_f = open("gip_led_log.txt", "w")
def log(msg):
    line = f"{time.strftime('%H:%M:%S')} {msg}"
    print(line); log_f.write(line + "\n"); log_f.flush()

hx = lambda b: " ".join(f"{x:02x}" for x in b)

def varint_enc(n):
    out = bytearray()
    while True:
        b = n & 0x7F; n >>= 7
        out.append(b | (0x80 if n else 0))
        if not n: return bytes(out)

def varint_dec(buf, i):
    n = shift = 0
    while True:
        b = buf[i]; i += 1
        n |= (b & 0x7F) << shift; shift += 7
        if not b & 0x80: return n, i

dev = usb.core.find(idVendor=VID, idProduct=PID)
if dev is None: raise SystemExit("Wheel not found.")
try: dev.set_configuration()
except usb.core.USBError: pass
usb.util.claim_interface(dev, 0)

seq = 0
lock = threading.Lock()
def send(cmd, opts, payload=b"", sequence=None, quiet=False):
    global seq
    with lock:
        if sequence is None:
            seq = (seq % 255) + 1; sequence = seq
        pkt = bytes([cmd, opts, sequence]) + varint_enc(len(payload)) + bytes(payload)
        dev.write(EP_OUT, pkt, 1000)
    if not quiet: log(f"OUT {hx(pkt)}")

def ack(cmd, opts, sequence, received, total):
    payload = bytes([0x00, cmd, OPT_INTERNAL | (opts & 0x0F)]) + received.to_bytes(2, "little") \
              + b"\x00\x00" + max(total - received, 0).to_bytes(2, "little")
    send(0x01, OPT_INTERNAL, payload, sequence, quiet=True)

chunks, stop = {}, False
def handle(pkt):
    cmd, opts, sq = pkt[0], pkt[1], pkt[2]
    length, i = varint_dec(pkt, 3)
    if opts & OPT_CHUNK:
        offset, i = varint_dec(pkt, i)
        if opts & OPT_CHUNK_START:
            chunks[cmd] = offset; offset = 0
        total = chunks.get(cmd, 0)
        if opts & OPT_ACK: ack(cmd, opts, sq, offset + length, total)
        return
    if opts & OPT_ACK: ack(cmd, opts, sq, length, length)
    if cmd not in (0x20, 0x03):
        log(f"IN  cmd 0x{cmd:02x} opts {opts:02x} {hx(pkt[i:i+length])}")

def reader():
    while not stop:
        try: pkt = bytes(dev.read(EP_IN, 64, 200))
        except usb.core.USBError: continue
        if pkt: handle(pkt)
threading.Thread(target=reader, daemon=True).start()

# Handshake
send(0x04, OPT_INTERNAL); time.sleep(2)
send(0x05, OPT_INTERNAL, b"\x00"); time.sleep(1)
log("Handshake done. Watch the 4 rev LEDs and the mode LED.")

def test(label, cmd, payload, opts=0x00):
    log(f"--- {label}")
    send(cmd, opts, payload)
    seen = input("    What happened? (Enter = nothing): ").strip()
    log(f"    RESULT: {seen or 'nothing'}")

# 1. Standard GIP LED message (0x0a, 3 bytes) - usually the guide/mode LED
test("0x0a guide LED on, brightness 20", 0x0A, [0x00, 0x01, 0x14], OPT_INTERNAL)
test("0x0a guide LED fast blink",        0x0A, [0x00, 0x02, 0x14], OPT_INTERNAL)
test("0x0a guide LED restore (on)",      0x0A, [0x00, 0x01, 0x14], OPT_INTERNAL)

# 2. Vendor message 0x0c (9 bytes, host-to-device) - prime rev LED candidate
test("0x0c all 0xff", 0x0C, [0xFF] * 9)
test("0x0c all zero", 0x0C, [0x00] * 9)
for i in range(9):
    p = [0x00] * 9; p[i] = 0xFF
    test(f"0x0c byte {i} = ff", 0x0C, p)
for v in (0x01, 0x03, 0x07, 0x0F):
    test(f"0x0c byte 0 = {v:02x}, byte 1 = {v:02x}", 0x0C, [v, v] + [0] * 7)
test("0x0c clear", 0x0C, [0x00] * 9)

stop = True
time.sleep(0.3)
usb.util.release_interface(dev, 0)
log("Done. Paste gip_led_log.txt back to Claude.")
