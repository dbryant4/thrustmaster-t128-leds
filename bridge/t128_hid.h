// Windows half of the T128 LED bridge: find the wheel in PC HID mode (044f:b696) and send
// 0x60 packets to it. Protocol notes are in CLAUDE.md; t128-c/t128_signals_demo.c is the
// reference this was ported from.
#ifndef T128_HID_H
#define T128_HID_H

#include <windows.h>
#include <setupapi.h>
#include <hidsdi.h>
#include <hidpi.h>
#include "t128_logic.h"

#define T128_VID 0x044f
#define T128_PID 0xb696
#define T128_KEEPALIVE_MS 450

typedef struct {
    HANDLE h;
    USHORT outLen;
    int useSetReport;   // 0 = WriteFile, 1 = HidD_SetOutputReport
    int failures;       // consecutive failed writes
    DWORD lastKeep;
} T128;

static int t128_write(T128 *w, const unsigned char *p, int n) {
    unsigned char buf[256] = {0};
    memcpy(buf, p, n);
    DWORD wrote = 0;
    BOOL ok = w->useSetReport ? HidD_SetOutputReport(w->h, buf, w->outLen)
                              : WriteFile(w->h, buf, w->outLen, &wrote, NULL);
    w->failures = ok ? 0 : w->failures + 1;
    return ok;
}

// Frames up to 10 bytes go in one packet, longer ones in 8-byte chunks, as the driver does.
static int t128_send(T128 *w, const unsigned char *pl, int pn) {
    unsigned char fr[64];
    int n = t128_make_frame(pl, pn, fr), ok = 1;
    int size = n <= 10 ? n : 8;
    for (int i = 0; i < n; i += size) {
        int c = (n - i < size) ? n - i : size;
        unsigned char pkt[64] = {0x60, 0x00, 0x42, (unsigned char)c};
        memcpy(pkt + 4, fr + i, c);
        ok &= t128_write(w, pkt, 4 + c);
    }
    return ok;
}

static void t128_keepalive(T128 *w) {
    if (GetTickCount() - w->lastKeep > T128_KEEPALIVE_MS) {
        t128_send(w, NULL, 0);
        w->lastKeep = GetTickCount();
    }
}

static int t128_set_value(T128 *w, int v) {
    unsigned char pl[4] = {0x54, 0x08, (unsigned char)(v & 0xff), (unsigned char)(v >> 8)};
    return t128_send(w, pl, 4);
}

// Config blob and start byte the Thrustmaster driver sends before telemetry.
static void t128_start_session(T128 *w) {
    static const unsigned char cfg[] = {0x1f,0x01,0xf4,0x65,0x00,0x0a,0x71,0x02,0x00,0x02,0x25,0x7a,0x35,0xe5,0x03};
    static const unsigned char start[] = {0x21};
    for (int i = 0; i < 5; i++) { t128_keepalive(w); t128_send(w, cfg, sizeof(cfg)); Sleep(90); }
    t128_send(w, start, sizeof(start));
    Sleep(50);
}

static void t128_close(T128 *w) {
    if (w->h != INVALID_HANDLE_VALUE) CloseHandle(w->h);
    w->h = INVALID_HANDLE_VALUE;
}

// Opens the first writable 044f:b696 interface that accepts a keepalive. Returns 1 on success.
static int t128_open(T128 *w) {
    GUID g; HidD_GetHidGuid(&g);
    HDEVINFO set = SetupDiGetClassDevsA(&g, NULL, NULL, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
    if (set == INVALID_HANDLE_VALUE) return 0;
    SP_DEVICE_INTERFACE_DATA ifd; memset(&ifd, 0, sizeof(ifd)); ifd.cbSize = sizeof(ifd);
    int found = 0;
    for (DWORD i = 0; !found && SetupDiEnumDeviceInterfaces(set, NULL, &g, i, &ifd); i++) {
        DWORD need = 0;
        SetupDiGetDeviceInterfaceDetailA(set, &ifd, NULL, 0, &need, NULL);
        PSP_DEVICE_INTERFACE_DETAIL_DATA_A det = malloc(need);
        if (!det) break;
        det->cbSize = sizeof(*det);
        if (!SetupDiGetDeviceInterfaceDetailA(set, &ifd, det, need, NULL, NULL)) { free(det); continue; }
        HANDLE h = CreateFileA(det->DevicePath, GENERIC_READ | GENERIC_WRITE,
                               FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
        free(det);
        if (h == INVALID_HANDLE_VALUE) continue;

        HIDD_ATTRIBUTES at; memset(&at, 0, sizeof(at)); at.Size = sizeof(at);
        PHIDP_PREPARSED_DATA pp = NULL; HIDP_CAPS caps; memset(&caps, 0, sizeof(caps));
        if (HidD_GetAttributes(h, &at) && at.VendorID == T128_VID && at.ProductID == T128_PID &&
            HidD_GetPreparsedData(h, &pp)) {
            HidP_GetCaps(pp, &caps);
            HidD_FreePreparsedData(pp);
        }
        if (caps.OutputReportByteLength == 0 || caps.OutputReportByteLength > 256) { CloseHandle(h); continue; }

        w->h = h; w->outLen = caps.OutputReportByteLength; w->lastKeep = GetTickCount();
        for (w->useSetReport = 0; w->useSetReport < 2 && !found; w->useSetReport++) {
            w->failures = 0;
            found = t128_send(w, NULL, 0);
            if (found) break;
        }
        if (!found) t128_close(w);
    }
    SetupDiDestroyDeviceInfoList(set);
    return found;
}

#endif
