// FS25 -> Thrustmaster T128 rev LEDs. Polls the telemetry file written by the
// FS25_T128Telemetry mod and shows engine RPM, turn signals and hazards on the wheel.
//
// Build: x86_64-w64-mingw32-gcc -O2 -static fs25_t128_leds.c -o fs25_t128_leds.exe -lhid -lsetupapi
#include <windows.h>
#include <shlobj.h>
#include <stdio.h>
#include <string.h>
#include "t128_hid.h"

#define VERSION "0.1.0"
#define LOOP_MS 50            // 20 Hz telemetry to the wheel
#define STALE_MS 1500         // no new write from the game for this long = LEDs off
#define REOPEN_MS 1000
#define MAX_WRITE_FAILURES 10

static volatile LONG quit;

static BOOL WINAPI on_ctrl(DWORD type) {
    quit = 1;
    // Closing the window kills the process when this returns; give main() time to clear the LEDs.
    if (type != CTRL_C_EVENT && type != CTRL_BREAK_EVENT) Sleep(800);
    return TRUE;
}

static int read_text(const char *path, char *buf, int cap) {
    // Share everything and close straight away so the game can always rewrite the file.
    HANDLE f = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                           NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (f == INVALID_HANDLE_VALUE) return 0;
    DWORD n = 0;
    BOOL ok = ReadFile(f, buf, cap - 1, &n, NULL);
    CloseHandle(f);
    buf[ok ? n : 0] = 0;
    return ok && n > 0;
}

static void usage(void) {
    printf("Usage: fs25_t128_leds [--fake] [--no-flash] [--file <telemetry.xml>]\n\n"
           "  --fake       ignore the game and play a built-in RPM/signal loop (hardware test)\n"
           "  --no-flash   cap the RPM bar at 4 LEDs instead of flashing near max RPM\n"
           "  --file PATH  telemetry file; default is\n"
           "               Documents\\My Games\\FarmingSimulator2025\\modSettings\\FS25_T128Telemetry\\telemetry.xml\n");
}

int main(int argc, char **argv) {
    int fake = 0, allowFlash = 1;
    char path[MAX_PATH * 2] = {0};
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--fake")) fake = 1;
        else if (!strcmp(argv[i], "--no-flash")) allowFlash = 0;
        else if (!strcmp(argv[i], "--file") && i + 1 < argc) snprintf(path, sizeof(path), "%s", argv[++i]);
        else { usage(); return strcmp(argv[i], "--help") ? 1 : 0; }
    }
    if (!path[0]) {
        char docs[MAX_PATH] = {0};
        if (SHGetFolderPathA(NULL, CSIDL_PERSONAL, NULL, SHGFP_TYPE_CURRENT, docs) != S_OK) {
            printf("Could not locate the Documents folder; pass --file.\n");
            return 1;
        }
        snprintf(path, sizeof(path), "%s\\My Games\\FarmingSimulator2025\\modSettings\\FS25_T128Telemetry\\telemetry.xml", docs);
    }

    printf("FS25 -> T128 LEDs %s\n", VERSION);
    if (fake) printf("Source: built-in fake telemetry\n");
    else printf("Source: %s\n", path);
    printf("Close Fanaleds and the Thrustmaster control panel. Ctrl+C to quit.\n\n");
    SetConsoleCtrlHandler(on_ctrl, TRUE);

    T128 wheel = {INVALID_HANDLE_VALUE, 64, 0, 0, 0};
    Telemetry tel = {0};
    LedState leds = {0};
    DWORD lastOpenTry = GetTickCount() - REOPEN_MS, lastFresh = GetTickCount() - STALE_MS;
    int lastSeq = -1, wheelOk = 0;

    while (!quit) {
        DWORD now = GetTickCount();

        if (!wheelOk && now - lastOpenTry >= REOPEN_MS) {
            lastOpenTry = now;
            wheelOk = t128_open(&wheel);
            if (wheelOk) {
                printf("\rWheel connected (%s, %u-byte reports)%20s\n",
                       wheel.useSetReport ? "HidD_SetOutputReport" : "WriteFile", wheel.outLen, "");
                t128_start_session(&wheel);
                now = GetTickCount();
            }
        }

        int live;
        if (fake) {
            telemetry_fake(now, &tel);
            live = 1;
        } else {
            char buf[1024];
            Telemetry t;
            if (read_text(path, buf, sizeof(buf)) && telemetry_parse(buf, &t)) {
                if (t.seq != lastSeq) { lastSeq = t.seq; lastFresh = now; }
                tel = t;
            }
            live = now - lastFresh < STALE_MS;
            if (!live) memset(&tel, 0, sizeof(tel));
        }

        int lit = led_update(&leds, &tel, now, allowFlash);

        if (wheelOk) {
            t128_keepalive(&wheel);
            t128_set_value(&wheel, T128_LED_VALUE[lit]);
            if (wheel.failures >= MAX_WRITE_FAILURES) {
                printf("\rWheel disconnected (error %lu); waiting for it to come back%10s\n", GetLastError(), "");
                t128_close(&wheel);
                wheelOk = 0;
            }
        }

        static const char *turnNames[] = {"-", "LEFT", "RIGHT", "HAZARD"};
        static const char *bars[] = {"....", "#...", "##..", "###.", "####", "FLASH"};
        printf("\r  game %-7s wheel %-7s rpm %4d/%4d  %3d km/h  signal %-6s LEDs %-5s ",
               live ? (tel.active ? "driving" : "on foot") : "waiting", wheelOk ? "ok" : "missing",
               tel.rpm, tel.maxRpm, tel.speed, turnNames[tel.turn & 3], bars[lit]);
        fflush(stdout);
        Sleep(LOOP_MS);
    }

    if (wheelOk) {
        for (int i = 0; i < 6; i++) { t128_keepalive(&wheel); t128_set_value(&wheel, 0); Sleep(LOOP_MS); }
        t128_close(&wheel);
    }
    printf("\nLEDs cleared. Bye.\n");
    return 0;
}
