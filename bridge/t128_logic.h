// Portable half of the T128 LED bridge: wire framing, FS25 telemetry parsing and the
// telemetry -> LED count logic. No Windows dependencies, so test_logic.c can run it on any host.
#ifndef T128_LOGIC_H
#define T128_LOGIC_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// ---- framing -------------------------------------------------------------

static unsigned short t128_crc16(unsigned short c, const unsigned char *d, int n) {
    for (int i = 0; i < n; i++) {
        c ^= d[i];
        for (int b = 0; b < 8; b++) c = (c & 1) ? (c >> 1) ^ 0x8005 : c >> 1;
    }
    return c;
}

// frame = d0 63 | len u16 | crc u16 | payload. Returns the frame length.
static int t128_make_frame(const unsigned char *pl, int pn, unsigned char *out) {
    int n = 6 + pn;
    out[0] = 0xd0; out[1] = 0x63; out[2] = n & 0xff; out[3] = n >> 8;
    unsigned short c = t128_crc16(0, out, 4);
    if (pn > 0) { c = t128_crc16(c, pl, pn); memcpy(out + 6, pl, pn); }
    out[4] = c & 0xff; out[5] = c >> 8;
    return n;
}

// Telemetry values that land safely inside each measured band (first field 0x0854):
// 1 LED 460-589, 2 LEDs 590-709, 3 LEDs 710-819, 4 LEDs 820-919, firmware flash >= 920.
// Index = LEDs lit, 5 = flash.
static const int T128_LED_VALUE[6] = {0, 520, 650, 765, 870, 960};

// ---- telemetry from the FS25 mod ------------------------------------------

enum { TURN_OFF = 0, TURN_LEFT = 1, TURN_RIGHT = 2, TURN_HAZARD = 3 };

typedef struct {
    int seq;      // changes on every write by the mod
    int active;   // 1 while the player sits in a motorized vehicle
    int motor;    // 1 while the engine is running
    int rpm, minRpm, maxRpm;
    int speed;    // km/h
    int turn;     // TURN_*
} Telemetry;

// Reads name="123" from the text. A value without its closing quote (file caught
// mid-write) does not count.
static int telemetry_attr(const char *xml, const char *name, int *out) {
    char pat[32];
    snprintf(pat, sizeof(pat), " %s=\"", name);
    const char *p = strstr(xml, pat);
    if (!p) return 0;
    p += strlen(pat);
    char *end;
    long v = strtol(p, &end, 10);
    if (end == p || *end != '"') return 0;
    *out = (int)v;
    return 1;
}

// Returns 1 and fills *t only if every field is present.
static int telemetry_parse(const char *xml, Telemetry *t) {
    Telemetry n;
    if (!telemetry_attr(xml, "seq", &n.seq) || !telemetry_attr(xml, "active", &n.active) ||
        !telemetry_attr(xml, "motor", &n.motor) || !telemetry_attr(xml, "rpm", &n.rpm) ||
        !telemetry_attr(xml, "minRpm", &n.minRpm) || !telemetry_attr(xml, "maxRpm", &n.maxRpm) ||
        !telemetry_attr(xml, "speed", &n.speed) || !telemetry_attr(xml, "turn", &n.turn))
        return 0;
    *t = n;
    return 1;
}

// The heartbeat the bridge leaves beside the telemetry file (bridge.xml). The mod writes
// telemetry only while beat keeps changing and wheel is 1, so on a PC without the bridge or
// without the wheel (other players in a multiplayer game) the mod does nothing.
// XML because that is the one kind of file the game's Lua can read back.
static int bridge_beat_format(char *out, size_t cap, int beat, int wheel) {
    return snprintf(out, cap, "<?xml version=\"1.0\" encoding=\"utf-8\" standalone=\"no\"?>\n"
                              "<bridge version=\"1\" beat=\"%d\" wheel=\"%d\"/>\n", beat, wheel ? 1 : 0);
}

// Stand-in for the game: a 40 s loop of an RPM sweep, right signal, left signal, hazards, idle.
static void telemetry_fake(unsigned nowMs, Telemetry *t) {
    unsigned ph = nowMs % 40000;
    t->seq = (int)(nowMs / 50);
    t->active = 1; t->motor = 1;
    t->minRpm = 800; t->maxRpm = 2200; t->rpm = 800; t->speed = 0; t->turn = TURN_OFF;
    if (ph < 16000) {
        unsigned up = ph < 8000 ? ph : 16000 - ph;   // 0..8000..0
        t->rpm = 800 + (int)(up * 1400 / 8000);
        t->speed = (int)(up * 40 / 8000);
    } else if (ph < 22000) t->turn = TURN_RIGHT;
    else if (ph < 28000) t->turn = TURN_LEFT;
    else if (ph < 34000) t->turn = TURN_HAZARD;
}

// ---- LED logic ------------------------------------------------------------

// 1/2/3/4 LEDs at 55/68/80/92% of max RPM, firmware flash at 95%.
static const double RPM_LED_ON[5] = {0.55, 0.68, 0.80, 0.92, 0.95};
#define RPM_LED_HYST 0.015   // a level is held until RPM falls this far below its threshold

// prev = level returned last time; stops a threshold-straddling RPM from flickering.
static int rpm_leds(double frac, int prev, int allowFlash) {
    int lit = 0;
    for (int i = 0; i < 5; i++) if (frac >= RPM_LED_ON[i]) lit = i + 1;
    if (lit < prev && prev >= 1 && prev <= 5 && frac >= RPM_LED_ON[prev - 1] - RPM_LED_HYST) lit = prev;
    if (!allowFlash && lit > 4) lit = 4;
    return lit;
}

// The firmware only draws a bar from LED 1 upward, so signals are bar animations.
static int signal_leds(int turn, unsigned phaseMs) {
    unsigned step = (phaseMs / 130) % 6;
    switch (turn) {
    case TURN_LEFT:   return step < 4 ? 4 - (int)step : 0;       // 4,3,2,1,off,off: drains right -> left
    case TURN_RIGHT:  return step < 4 ? (int)step + 1 : 0;       // 1,2,3,4,off,off: fills left -> right
    case TURN_HAZARD: return ((phaseMs / 380) % 2) ? 0 : 4;      // all on / all off
    default:          return 0;
    }
}

#define IDLE_BLINK_MS 1000   // LED 1 on for this long, then off for this long

typedef struct {
    int turn;            // signal currently animating
    unsigned turnStart;  // when it started, ms
    int rpmLit;          // last RPM level, for hysteresis
    int idling;          // engine running below the first RPM threshold
    unsigned idleStart;  // when that began, ms
} LedState;

typedef struct {
    int allowFlash;      // let the firmware flash near max RPM
    int idleBlink;       // blink LED 1 slowly while the engine runs below the bar's first step
} LedOptions;

// Returns LEDs to light: 0-4, or 5 for the firmware flash. Signals override RPM.
static int led_update(LedState *s, const Telemetry *t, unsigned nowMs, LedOptions opt) {
    if (!t->active) { s->turn = TURN_OFF; s->rpmLit = 0; s->idling = 0; return 0; }
    if (t->turn != s->turn) { s->turn = t->turn; s->turnStart = nowMs; }
    if (s->turn != TURN_OFF) { s->rpmLit = 0; s->idling = 0; return signal_leds(s->turn, nowMs - s->turnStart); }
    if (!t->motor || t->maxRpm <= 0) { s->rpmLit = 0; s->idling = 0; return 0; }
    s->rpmLit = rpm_leds((double)t->rpm / t->maxRpm, s->rpmLit, opt.allowFlash);
    if (s->rpmLit > 0 || !opt.idleBlink) { s->idling = 0; return s->rpmLit; }
    // "Engine is running": starts lit, so starting the engine shows at once.
    if (!s->idling) { s->idling = 1; s->idleStart = nowMs; }
    return ((nowMs - s->idleStart) / IDLE_BLINK_MS) % 2 ? 0 : 1;
}

#endif
