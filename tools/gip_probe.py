#!/usr/bin/env python3
"""GIP probe for the Thrustmaster T128X (044f:b69c) on macOS/Linux.

Claims the vendor interface, listens for the device announce, requests the
Identify descriptor (lists the message types the wheel supports), powers the
wheel on, then logs input while you turn the wheel and press buttons.

Everything is written to gip_log.txt. Keep hands off the rim.
"""
import sys, time, threading, string
import usb.core, usb.util

VID, PID = 0x044F, 0xB69C
EP_OUT, EP_IN = 0x01, 0x81
OPT_ACK, OPT_INTERNAL, OPT_CHUNK_START, OPT_CHUNK = 0x10, 0x20, 0x40, 0x80
NAMES = {0x01: "ack", 0x02: "announce", 0x03: "status", 0x04: "identify",
         0x05: "power", 0x06: "auth", 0x07: "guide", 0x0A: "led", 0x20: "input"}

log_f = open("gip_log.txt", "w")
def log(msg):
    line = f"{time.strftime('%H:%M:%S')} {msg}"
    print(line); log_f.write(line + "\n"); log_f.flush()

def hx(b): return " ".join(f"{x:02x}" for x in b)

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
if dev is None: sys.exit("Wheel not found (044f:b69c). Is it plugged in and powered?")
try: dev.set_configuration()
except usb.core.USBError as e: log(f"set_configuration: {e} (continuing)")
usb.util.claim_interface(dev, 0)
log(f"Claimed {dev.product} {VID:04x}:{PID:04x}")

seq = 0
def send(cmd, opts, payload=b"", sequence=None):
    global seq
    if sequence is None:
        seq = (seq % 255) + 1; sequence = seq
    pkt = bytes([cmd, opts, sequence]) + varint_enc(len(payload)) + payload
    dev.write(EP_OUT, pkt, 1000)
    log(f"OUT {NAMES.get(cmd, hex(cmd)):>9} {hx(pkt)}")

def ack(cmd, opts, sequence, received, total):
    payload = bytes([0x00, cmd, OPT_INTERNAL | (opts & 0x0F)]) + received.to_bytes(2, "little") \
              + b"\x00\x00" + max(total - received, 0).to_bytes(2, "little")
    send(0x01, OPT_INTERNAL, payload, sequence)

chunks = {}       # cmd -> {"total": n, "data": bytearray}
identify = None
last_input = None
stop = False

def handle(pkt):
    global identify, last_input
    cmd, opts, sq = pkt[0], pkt[1], pkt[2]
    length, i = varint_dec(pkt, 3)
    if opts & OPT_CHUNK:
        offset, i = varint_dec(pkt, i)
        data = pkt[i:i + length]
        if opts & OPT_CHUNK_START:
            chunks[cmd] = {"total": offset, "data": bytearray(offset)}
            offset = 0
        st = chunks.get(cmd)
        if st is None: log(f"chunk without start: {hx(pkt)}"); return
        if length:
            st["data"][offset:offset + length] = data
        received = offset + length
        if opts & OPT_ACK: ack(cmd, opts, sq, received, st["total"])
        if length == 0 or received >= st["total"]:
            log(f"IN  {NAMES.get(cmd, hex(cmd)):>9} complete, {st['total']} bytes")
            if cmd == 0x04: identify = bytes(st["data"])
            chunks.pop(cmd, None)
        return
    data = pkt[i:i + length]
    if opts & OPT_ACK: ack(cmd, opts, sq, length, length)
    if cmd == 0x20:
        if data != last_input:
            log(f"IN      input {hx(data)}"); last_input = data
        return
    if cmd == 0x04: identify = bytes(data)
    log(f"IN  {NAMES.get(cmd, hex(cmd)):>9} opts={opts:02x} {hx(data)}")

def reader():
    while not stop:
        try: pkt = bytes(dev.read(EP_IN, 64, 200))
        except usb.core.USBTimeoutError: continue
        except usb.core.USBError as e:
            if "timed out" in str(e).lower(): continue
            log(f"read error: {e}"); time.sleep(0.2); continue
        if pkt: handle(pkt)

t = threading.Thread(target=reader, daemon=True); t.start()

log("Listening for announce (3s)...")
time.sleep(3)

log("Requesting identify...")
send(0x04, OPT_INTERNAL)
time.sleep(3)
if identify:
    log(f"IDENTIFY ({len(identify)} bytes):")
    for off in range(0, len(identify), 32):
        log(f"  {off:04x}  {hx(identify[off:off+32])}")
    s = "".join(chr(b) if chr(b) in string.printable and b >= 0x20 else "\n" for b in identify)
    names = [x for x in s.split("\n") if len(x) >= 6]
    log("IDENTIFY strings: " + " | ".join(names))
else:
    log("No identify response. Replug the wheel and run again.")

log("Powering on...")
send(0x05, OPT_INTERNAL, b"\x00")
log("Turn the wheel, press pedals and buttons for 15s...")
time.sleep(15)

stop = True; t.join(1)
usb.util.release_interface(dev, 0)
log("Done. Paste gip_log.txt back to Claude.")
