// T128 rev-LED test for Windows. Replays the telemetry protocol decoded from the
// Thrustmaster driver capture. Writes a log to t128_led_log.txt next to the exe.
#include <windows.h>
#include <setupapi.h>
#include <hidsdi.h>
#include <hidpi.h>
#include <stdio.h>
#include <stdarg.h>
#include <string.h>

static FILE *logf;
static void say(const char *fmt, ...) {
    va_list a; va_start(a, fmt); vprintf(fmt, a); va_end(a);
    if (logf) { va_start(a, fmt); vfprintf(logf, fmt, a); va_end(a); fflush(logf); }
}

static HANDLE dev = INVALID_HANDLE_VALUE;
static USHORT outLen = 64;
static int writeMode = 0;   // 0 = WriteFile, 1 = HidD_SetOutputReport
static int writeFailures = 0;

static unsigned short crc16(const unsigned char *d, int n) {
    unsigned short c = 0;
    for (int i = 0; i < n; i++) {
        c ^= d[i];
        for (int b = 0; b < 8; b++) c = (c & 1) ? (c >> 1) ^ 0x8005 : c >> 1;
    }
    return c;
}

// frame = d0 63 | len u16 | crc u16 | payload
static int make_frame(const unsigned char *pl, int pn, unsigned char *out) {
    int n = 6 + pn;
    unsigned char tmp[64];
    out[0] = 0xd0; out[1] = 0x63; out[2] = n & 0xff; out[3] = n >> 8;
    memcpy(tmp, out, 4); memcpy(tmp + 4, pl, pn);
    unsigned short c = crc16(tmp, 4 + pn);
    out[4] = c & 0xff; out[5] = c >> 8;
    memcpy(out + 6, pl, pn);
    return n;
}

static int write_packet(const unsigned char *p, int n) {
    unsigned char buf[256] = {0};
    memcpy(buf, p, n);
    BOOL ok; DWORD wrote = 0;
    if (writeMode == 0) ok = WriteFile(dev, buf, outLen, &wrote, NULL);
    else ok = HidD_SetOutputReport(dev, buf, outLen);
    if (!ok) {
        if (writeFailures++ < 5) say("  write failed (mode %d), error %lu\n", writeMode, GetLastError());
        return 0;
    }
    return 1;
}

static void send_frame(const unsigned char *fr, int n) {
    int size = n <= 10 ? n : 8;   // match the driver's chunking
    for (int i = 0; i < n; i += size) {
        int c = (n - i < size) ? n - i : size;
        unsigned char pkt[64] = {0x60, 0x00, 0x42, (unsigned char)c};
        memcpy(pkt + 4, fr + i, c);
        write_packet(pkt, 4 + c);
    }
}

static DWORD lastKeep = 0;
static void tick(void) {
    if (GetTickCount() - lastKeep > 450) {
        unsigned char fr[16]; int n = make_frame(NULL, 0, fr);
        send_frame(fr, n); lastKeep = GetTickCount();
    }
}

static void telemetry(int a, int b, int v) {
    unsigned char pl[4] = {(unsigned char)a, (unsigned char)b, (unsigned char)(v & 0xff), (unsigned char)(v >> 8)};
    unsigned char fr[16]; int n = make_frame(pl, 4, fr);
    send_frame(fr, n);
}

static void hold(int ms, int v) {
    DWORD end = GetTickCount() + ms;
    while (GetTickCount() < end) { tick(); telemetry(0x54, 0x08, v); Sleep(100); }
}

static int self_test(void) {
    unsigned char fr[32];
    unsigned char t1[] = {0x54, 0x08, 0xbf, 0x02};
    make_frame(t1, 4, fr);
    unsigned char e1[] = {0xd0,0x63,0x0a,0x00,0xfc,0x89,0x54,0x08,0xbf,0x02};
    if (memcmp(fr, e1, 10)) return 0;
    make_frame(NULL, 0, fr);
    unsigned char e2[] = {0xd0,0x63,0x06,0x00,0xe6,0xb8};
    return memcmp(fr, e2, 6) == 0;
}

static void pause_exit(int code) {
    say("\nPress Enter to close.\n"); getchar();
    if (logf) fclose(logf);
    exit(code);
}

int main(void) {
    logf = fopen("t128_led_log.txt", "w");
    say("T128 LED test\n=============\n");
    if (!self_test()) { say("CRC self-test FAILED\n"); pause_exit(1); }
    say("CRC self-test OK\n\nClose Fanaleds, games and the Thrustmaster control panel first.\n\n");

    GUID g; HidD_GetHidGuid(&g);
    HDEVINFO set = SetupDiGetClassDevsA(&g, NULL, NULL, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
    SP_DEVICE_INTERFACE_DATA ifd = {sizeof(ifd)};
    char chosen[1024] = {0};
    say("Thrustmaster HID interfaces:\n");
    for (DWORD i = 0; SetupDiEnumDeviceInterfaces(set, NULL, &g, i, &ifd); i++) {
        DWORD need = 0;
        SetupDiGetDeviceInterfaceDetailA(set, &ifd, NULL, 0, &need, NULL);
        PSP_DEVICE_INTERFACE_DETAIL_DATA_A det = malloc(need);
        det->cbSize = sizeof(*det);
        if (!SetupDiGetDeviceInterfaceDetailA(set, &ifd, det, need, NULL, NULL)) { free(det); continue; }
        HANDLE h = CreateFileA(det->DevicePath, GENERIC_READ | GENERIC_WRITE,
                               FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
        int rw = 1;
        if (h == INVALID_HANDLE_VALUE) {
            rw = 0;
            h = CreateFileA(det->DevicePath, 0, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
        }
        if (h != INVALID_HANDLE_VALUE) {
            HIDD_ATTRIBUTES at = {sizeof(at)};
            if (HidD_GetAttributes(h, &at) && at.VendorID == 0x044f) {
                wchar_t name[128] = L"?"; HidD_GetProductString(h, name, sizeof(name));
                PHIDP_PREPARSED_DATA pp; HIDP_CAPS caps = {0};
                if (HidD_GetPreparsedData(h, &pp)) { HidP_GetCaps(pp, &caps); }
                say("  PID %04x \"%ls\" page %04x usage %04x in %u out %u feat %u %s\n",
                    at.ProductID, name, caps.UsagePage, caps.Usage, caps.InputReportByteLength,
                    caps.OutputReportByteLength, caps.FeatureReportByteLength, rw ? "" : "(read-only open)");
                if (caps.NumberOutputValueCaps) {
                    HIDP_VALUE_CAPS vc[16]; USHORT nvc = 16;
                    if (HidP_GetValueCaps(HidP_Output, vc, &nvc, pp) == HIDP_STATUS_SUCCESS)
                        for (int k = 0; k < nvc; k++) say("      output report id 0x%02x\n", vc[k].ReportID);
                }
                if (rw && caps.OutputReportByteLength && !chosen[0]) {
                    strcpy(chosen, det->DevicePath); outLen = caps.OutputReportByteLength;
                }
                HidD_FreePreparsedData(pp);
            }
            CloseHandle(h);
        }
        free(det);
    }
    SetupDiDestroyDeviceInfoList(set);

    if (!chosen[0]) { say("\nNo writable Thrustmaster HID interface found.\n"); pause_exit(1); }
    dev = CreateFileA(chosen, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
                      NULL, OPEN_EXISTING, 0, NULL);
    say("\nUsing %s (output length %u)\n", chosen, outLen);

    // Probe which write path accepts a 0x60 packet
    unsigned char fr[32]; int n = make_frame(NULL, 0, fr);
    send_frame(fr, n);
    if (writeFailures) {
        say("WriteFile rejected the 0x60 packet; trying HidD_SetOutputReport\n");
        writeMode = 1; writeFailures = 0; send_frame(fr, n);
        if (writeFailures) { say("Both write paths rejected report 0x60. Paste the log to Claude.\n"); pause_exit(1); }
    }
    say("Keepalive accepted via %s\n\nPress Enter to start (keep hands off the rim)...", writeMode ? "HidD_SetOutputReport" : "WriteFile");
    getchar();

    unsigned char cfg[] = {0x1f,0x01,0xf4,0x65,0x00,0x0a,0x71,0x02,0x00,0x02,0x25,0x7a,0x35,0xe5,0x03};
    say("Sending config + start frames\n");
    for (int i = 0; i < 5; i++) { tick(); n = make_frame(cfg, sizeof(cfg), fr); send_frame(fr, n); Sleep(90); }
    unsigned char start[] = {0x21}; n = make_frame(start, 1, fr); send_frame(fr, n); Sleep(50);

    say("\nPhase 1: replay captured value 703 for 4 s\n"); hold(4000, 703);

    say("\nPhase 2: sweep 0 -> 2132. Note the value when each LED lights.\n");
    for (int v = 0; v <= 2132; v += 20) { printf("\r  value %5d", v); tick(); telemetry(0x54, 0x08, v); Sleep(100); }
    say("\n"); hold(3000, 2132);

    say("\nPhase 3: sweep first byte (in case 0x54 is the value)\n");
    for (int a = 0; a < 256; a += 8) { printf("\r  byte %3d", a); tick(); telemetry(a, 0x08, 0); Sleep(150); }
    say("\n");

    say("\nPhase 4: back to 0\n"); hold(2000, 0);
    say("\nDone. Tell Claude what lit up and at which values; t128_led_log.txt has the details.\n");
    CloseHandle(dev);
    pause_exit(0);
}
