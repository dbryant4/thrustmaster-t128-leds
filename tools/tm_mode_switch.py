#!/usr/bin/env python3
"""Ask the T128X to leave Xbox GIP mode (b69c) for Thrustmaster's PC HID mode.

Uses the vendor control requests from hid-tmff2 / the Windows driver analysis:
  query model:    0xC1 / 0x49, 16 bytes
  query firmware: 0xC1 / 0x56, 8 bytes
  switch mode:    0x41 / 0x53, wValue = switch code (T128 = 0x000b)
The queries are read-only. The switch only changes the USB mode until unplugged.
"""
import time
import usb.core

VID = 0x044F
hx = lambda b: " ".join(f"{x:02x}" for x in b)

def list_tm():
    found = list(usb.core.find(find_all=True, idVendor=VID))
    for d in found:
        try: name = d.product
        except Exception: name = "?"
        print(f"  {VID:04x}:{d.idProduct:04x}  {name}")
    return found

print("Thrustmaster devices now:")
devs = list_tm()
dev = next((d for d in devs if d.idProduct == 0xB69C), None)
if dev is None: raise SystemExit("T128X (b69c) not found.")

for name, req, length in (("model", 0x49, 16), ("firmware", 0x56, 8)):
    try:
        data = dev.ctrl_transfer(0xC1, req, 0, 0, length, timeout=1000)
        print(f"{name} query: {hx(data)}")
    except usb.core.USBError as e:
        print(f"{name} query failed: {e}")

codes = input("\nSwitch code(s) to try, comma-separated [0x000b]: ").strip() or "0x000b"
for code in [int(c, 16) for c in codes.split(",")]:
    print(f"\nSending switch 0x{code:04x}...")
    try:
        dev.ctrl_transfer(0x41, 0x53, code, 0, None, timeout=1000)
        print("  accepted")
    except usb.core.USBError as e:
        print(f"  {e} (a disconnect error here is normal if the wheel re-enumerated)")
    time.sleep(3)
    print("Thrustmaster devices now:")
    after = list_tm()
    if any(d.idProduct != 0xB69C for d in after):
        print("\nNew product ID appeared. Re-open t128-probe.html in Chrome and connect.")
        break
    dev = next((d for d in after if d.idProduct == 0xB69C), None)
    if dev is None: print("Wheel disappeared; give it a few seconds and rerun the listing."); break
